// BEHAVIOURAL handler tests for affiliate-sync.
//
// The defect class here was TRUTHFULNESS: a run whose database writes failed
// still reported `ok: true`, and the pg_cron dispatcher does not read the
// per-network summary — so a monitor watching `ok` saw a healthy ingestion that
// had stored nothing. These drive the real handler.

import { assertEquals } from 'https://deno.land/std@0.208.0/testing/asserts.ts';

const SECRET = 'worker-secret';
Deno.env.set('AFFILIATE_WORKER_SECRET', SECRET);

const { handleSync } = await import('./index.ts');

type Row = Record<string, unknown>;

/// Minimal PostgREST fake: enough of the chain for this handler, with the
/// failure points the run-status contract depends on.
class FakeDb {
  networks: Row[] = [];
  runs: Row[] = [];
  /// Every write to a table OTHER than the run log. Without this, a test named
  /// "does not ingest invisibly" could only see that no run row exists — it
  /// could not see ingestion continuing, which is the thing being forbidden.
  ingestWrites: string[] = [];
  failRunInsert = false;
  /// Fails ONLY the conversions run insert, so the offers run still succeeds —
  /// the transient-failure shape that the offers-only guard did not cover.
  failConversionRunInsert = false;
  failNetworkRead = false;
  failProgramRead = false;
  // ── The five store paths that were covered only at the ingest-contract
  // level. Each knob fails EVERY call on exactly one path inside makeStore /
  // makeConversionStore (in practice the first one throws and the run ends), so
  // a test can prove the failure reaches the RUN, not merely that the ingest
  // helper rethrows.
  failSourceRead = false;
  /// The error code the alias insert reports, or null for success. 23505 is
  /// expected and must NOT fail the run; anything else must.
  aliasInsertErrorCode: string | null = null;
  failConversionRead = false;
  failConversionInsert = false;
  failConversionUpdate = false;
  /// suggestAlias returns early unless the programme is bound to a merchant, so
  /// the alias insert is unreachable without this.
  programMerchantId: string | null = null;
  /// Makes findConversion report an EXISTING conversion, which is what routes
  /// reconciliation into updateConversion instead of insertConversion.
  existingConversion: Row | null = null;
  /// Conversion writes the handler ATTEMPTED, recorded before the knob decides
  /// whether to fail. Lets a test prove the path was genuinely exercised, so
  /// "nothing was committed" cannot pass by never reaching the write at all.
  conversionAttempts: string[] = [];
  /// Conversion writes that actually COMMITTED, identified by the conversion
  /// they touch — not merely counted, so a different mutation with the same
  /// count cannot pass.
  conversionCommits: string[] = [];
  /// Seeds the resume cursor read back from the last successful run.
  lastCursor: string | null = null;
  seq = 0;

  from(table: string) {
    // deno-lint-ignore no-this-alias
    const db = this;
    const filters: Array<[string, unknown]> = [];
    const api: Record<string, unknown> = {
      select: () => api,
      eq: (c: string, v: unknown) => { filters.push([c, v]); return api; },
      neq: () => resolve(),
      order: () => api,
      limit: () => api,
      insert(values: Row) {
        if (table === 'affiliate_ingestion_runs') {
          if (db.failRunInsert) {
            return chain({ data: null, error: { code: 'XX000' } });
          }
          if (db.failConversionRunInsert && values.kind === 'conversions') {
            return chain({ data: null, error: { code: 'XX000' } });
          }
          const row = { id: `run-${++db.seq}`, ...values };
          db.runs.push(row);
          return chain({ data: row, error: null });
        }
        if (table === 'catalog_merchant_aliases' && db.aliasInsertErrorCode != null) {
          return chain({ data: null, error: { code: db.aliasInsertErrorCode } });
        }
        if (table === 'affiliate_conversions') {
          const id = `insert:${values.external_conversion_id}`;
          db.conversionAttempts.push(id);
          if (db.failConversionInsert) {
            return chain({ data: null, error: { code: 'XX000' } });
          }
          db.conversionCommits.push(id);
        }
        db.ingestWrites.push(`insert:${table}`);
        // Every other insert returns a row WITH an id: PostgREST's
        // `.select('id').single()` does, and a fake that returns null makes the
        // caller throw — which would silently turn every "the good path still
        // works" assertion into a vacuous one.
        return chain({ data: { id: `${table}-${++db.seq}` }, error: null });
      },
      update(values: Row) {
        // PostgREST applies the filters that are chained AFTER update(), so the
        // mutation must be deferred until the builder is awaited. Applying it
        // eagerly writes every row and makes a later success overwrite the
        // failure this test is about.
        const apply = () => {
          if (table === 'affiliate_conversions') {
            const target = filters.find(([c]) => c === 'id')?.[1] ?? 'unknown';
            const id = `update:${target}:${JSON.stringify(values)}`;
            db.conversionAttempts.push(id);
            if (db.failConversionUpdate) return { data: null, error: { code: 'XX000' } };
            db.conversionCommits.push(id);
            return { data: null, error: null };
          }
          if (table !== 'affiliate_ingestion_runs') {
            db.ingestWrites.push(`update:${table}`);
            return { data: null, error: null };
          }
          for (const r of db.runs.filter((row) => filters.every(([c, v]) => row[c] === v))) {
            Object.assign(r, values);
          }
          return { data: null, error: null };
        };
        const builder: Record<string, unknown> = {
          eq: (c: string, v: unknown) => { filters.push([c, v]); return builder; },
          select: () => builder,
          single: () => Promise.resolve(apply()),
          maybeSingle: () => Promise.resolve(apply()),
          // deno-lint-ignore no-explicit-any
          then: (ok: any, err: any) => Promise.resolve(apply()).then(ok, err),
        };
        return builder;
      },
      maybeSingle: () => {
        if (table === 'affiliate_programs') {
          if (db.failProgramRead) {
            return Promise.resolve({ data: null, error: { code: 'XX000' } });
          }
          if (db.programMerchantId != null) {
            return Promise.resolve({
              data: { id: 'prog-1', merchant_id: db.programMerchantId },
              error: null,
            });
          }
        }
        if (table === 'affiliate_offer_sources' && db.failSourceRead) {
          return Promise.resolve({ data: null, error: { code: 'XX000' } });
        }
        if (table === 'affiliate_conversions') {
          if (db.failConversionRead) {
            return Promise.resolve({ data: null, error: { code: 'XX000' } });
          }
          return Promise.resolve({ data: db.existingConversion, error: null });
        }
        if (table === 'affiliate_ingestion_runs' && db.lastCursor != null) {
          return Promise.resolve({ data: { cursor: db.lastCursor }, error: null });
        }
        return Promise.resolve({ data: null, error: null });
      },
      single: () => Promise.resolve({ data: null, error: null }),
      then: undefined,
    };
    function resolve() {
      if (table === 'affiliate_networks') {
        return Promise.resolve(
          db.failNetworkRead
            ? { data: null, error: { code: 'XX000' } }
            : { data: db.networks, error: null },
        );
      }
      return Promise.resolve({ data: [], error: null });
    }
    function chain(result: unknown) {
      const p = Promise.resolve(result) as unknown as Record<string, unknown>;
      (p as { select?: unknown }).select = () => p;
      (p as { single?: unknown }).single = () => Promise.resolve(result);
      (p as { maybeSingle?: unknown }).maybeSingle = () => Promise.resolve(result);
      (p as { eq?: unknown }).eq = (c: string, v: unknown) => {
        filters.push([c, v]);
        return p;
      };
      return p;
    }
    return api;
  }
}

function authed(): Request {
  return new Request('https://x/affiliate-sync', {
    method: 'POST',
    headers: { authorization: `Bearer ${SECRET}` },
    body: '{}',
  });
}

Deno.test('an unauthenticated call is refused', async () => {
  const db = new FakeDb();
  const req = new Request('https://x/affiliate-sync', { method: 'POST', body: '{}' });
  // deno-lint-ignore no-explicit-any
  const res = await handleSync(req, () => db as any);
  assertEquals(res.status, 401);
});

Deno.test('a network READ failure is surfaced, not reported as success', async () => {
  const db = new FakeDb();
  db.failNetworkRead = true;
  // deno-lint-ignore no-explicit-any
  const res = await handleSync(authed(), () => db as any);
  assertEquals(res.status, 500);
  assertEquals((await res.json()).error, 'internal_error');
});

Deno.test('no configured networks is a truthful ok with nothing done', async () => {
  // Non-vacuity: the handler must not report failure merely because there is
  // no work — otherwise the failure assertions above prove nothing.
  const db = new FakeDb();
  // deno-lint-ignore no-explicit-any
  const res = await handleSync(authed(), () => db as any);
  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals(body.ok, true);
  assertEquals(body.failed_count, 0);
});

Deno.test('a configured network ingests successfully and reports ok:true', async () => {
  // THE paired positive for every failure assertion in this file. Without it a
  // handler that failed every configured network would satisfy all of them:
  // the only other ok:true case has no networks at all, which exercises none of
  // the ingest path.
  const db = new FakeDb();
  db.networks = [{ id: 'n1', network_key: 'fixture', status: 'active' }];
  // deno-lint-ignore no-explicit-any
  const res = await handleSync(authed(), () => db as any);
  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals(body.ok, true);
  assertEquals(body.failed_count, 0);
  assertEquals(
    db.runs.filter((r) => r.status === 'ok').length,
    2,
    `both the offers and conversions runs must close ok: ${JSON.stringify(db.runs)}`,
  );
  assertEquals(
    db.ingestWrites.length > 0,
    true,
    'a successful run must actually have written something',
  );
});

Deno.test('a run row that cannot be created does NOT ingest invisibly', async () => {
  // Without the guard the handler would do real ingestion work whose status
  // could never be written, leaving a run stuck at 'running' — or no auditable
  // record at all.
  const db = new FakeDb();
  db.networks = [{ id: 'n1', network_key: 'fixture', status: 'active' }];
  db.failRunInsert = true;
  // deno-lint-ignore no-explicit-any
  const res = await handleSync(authed(), () => db as any);
  const body = await res.json();
  assertEquals(body.ok, false, 'a run that could not be recorded is not success');
  assertEquals(res.status, 207);
  assertEquals(db.runs.length, 0, 'nothing left stuck at running');
  // The named property is "does not ingest", so observe ingestion, not just the
  // absence of a run row: a handler that skipped the run log and kept working
  // would satisfy the run-row assertion alone.
  assertEquals(
    db.ingestWrites,
    [],
    `no ingestion may happen without a run record: ${db.ingestWrites.join(',')}`,
  );
});

Deno.test('one failing network among several is reported, not averaged away', async () => {
  // The core truthfulness contract: `ok` was previously unconditional. Two
  // networks where only one fails is the case a single-network test cannot
  // distinguish — `ok` must follow the FAILURE, not the majority.
  const db = new FakeDb();
  db.networks = [
    { id: 'n1', network_key: 'fixture', status: 'active' },
    { id: 'n2', network_key: 'no-such-adapter', status: 'active' },
  ];
  db.failProgramRead = true;
  // deno-lint-ignore no-explicit-any
  const res = await handleSync(authed(), () => db as any);
  const body = await res.json();
  assertEquals(body.ok, false);
  assertEquals(body.failed_count > 0, true, 'the failure count must be visible');
  assertEquals(
    body.networks.some((n: Record<string, unknown>) => n.status === 'skipped'),
    true,
    'a network with no adapter is recorded as skipped, not silently dropped',
  );
});

Deno.test('a terminal adapter failure does NOT leave the run stuck at running', async () => {
  // The run row is inserted as 'running' before any ingestion. If a throw
  // escaped the try, that row would stay 'running' forever and the admin panel
  // would show a perpetually in-flight ingestion. A corrupt resume cursor is
  // the cheapest real way to make the adapter reject.
  const db = new FakeDb();
  db.networks = [{ id: 'n1', network_key: 'fixture', status: 'active' }];
  db.lastCursor = 'not-a-number';
  // deno-lint-ignore no-explicit-any
  const res = await handleSync(authed(), () => db as any);
  const body = await res.json();
  assertEquals(body.ok, false);
  // every() is true for an empty array, so first prove there is something to
  // close. Without this the assertion below passes when no run was created.
  assertEquals(db.runs.length > 0, true, 'a run must have been created to close');
  const stuck = db.runs.filter((r) => r.status === 'running');
  assertEquals(stuck.length, 0, `no run may remain running: ${JSON.stringify(db.runs)}`);
  assertEquals(
    db.runs.every((r) => r.status !== 'running' && r.finished_at != null),
    true,
    'every run must be closed with a finished_at',
  );
});

Deno.test('a database READ failure mid-ingest is surfaced, not counted as success', async () => {
  // `ensureProgram` reads before it inserts. A failed read that looked like
  // "absent" would make the ingest CREATE a duplicate program; it now throws,
  // and that throw must reach the summary rather than being absorbed.
  const db = new FakeDb();
  db.networks = [{ id: 'n1', network_key: 'fixture', status: 'active' }];
  db.failProgramRead = true;
  // deno-lint-ignore no-explicit-any
  const res = await handleSync(authed(), () => db as any);
  const body = await res.json();
  assertEquals(body.ok, false, 'a failed program read is not a healthy run');
  assertEquals(res.status, 207);
  assertEquals(
    db.runs.some((r) => r.status === 'failed' && r.safe_error_code === 'adapter_failed'),
    true,

    `the failure must be recorded on the run row: ${JSON.stringify(db.runs)}`,
  );
});

Deno.test('a conversions run row that cannot be created does NOT reconcile invisibly', async () => {
  // The offers run had this guard; the conversions run did not. A failed insert
  // left the run id null, reconciliation still wrote real money rows, and the
  // `convRun!.id` dereference then threw out of the loop — turning a partial
  // failure into a 500 with no summary, discarding the offers work already done.
  const db = new FakeDb();
  db.networks = [{ id: 'n1', network_key: 'fixture', status: 'active' }];
  db.failConversionRunInsert = true;
  // deno-lint-ignore no-explicit-any
  const res = await handleSync(authed(), () => db as any);
  assertEquals(res.status, 207, 'a partial failure is reported, not thrown');
  const body = await res.json();
  assertEquals(body.ok, false);
  assertEquals(
    body.networks.some((n: Record<string, unknown>) =>
      n.kind === 'conversions' && n.status === 'failed'
    ),
    true,
    `the conversions failure must be named: ${JSON.stringify(body.networks)}`,
  );
  // Non-vacuity: the offers half still succeeded and is still reported.
  assertEquals(
    db.runs.some((r) => r.kind === 'offers' && r.status === 'ok'),
    true,
    'the offers run must not be collateral damage',
  );
});

// ─────────────────────────────────────────────────────────────────────────────
// THE FIVE STORE FAILURE PATHS
//
// findSource, the alias insert, findConversion, insertConversion and
// updateConversion each used to discard the Supabase {error}. They were pinned
// only at the ingest-contract level, against a hand-written rejecting store —
// which proves ingestOffers/reconcileConversions rethrow, but NOT that the real
// store in index.ts propagates, nor that the failure reaches the run row and the
// response. These drive handleSync end to end.
// ─────────────────────────────────────────────────────────────────────────────

/// Exactly WHICH conversions a healthy run commits, measured rather than
/// hardcoded, so the assertions below compare identities and not a count that a
/// different mutation could coincidentally match.
async function baselineConversionCommits(): Promise<string[]> {
  const db = new FakeDb();
  db.networks = [{ id: 'n1', network_key: 'fixture', status: 'active' }];
  // deno-lint-ignore no-explicit-any
  await handleSync(authed(), () => db as any);
  return db.conversionCommits;
}

interface FailureExpectation {
  /// 'offers' or 'conversions' — which run must carry the failure.
  readonly kind: string;
  /// The run that must STILL have succeeded, proving independent work survives.
  readonly survives: string;
}

async function assertFailurePropagates(
  db: FakeDb,
  expect: FailureExpectation,
): Promise<void> {
  // deno-lint-ignore no-explicit-any
  const res = await handleSync(authed(), () => db as any);
  const body = await res.json();

  // (2) cannot result in ok: true
  assertEquals(body.ok, false, `ok must be false: ${JSON.stringify(body)}`);
  assertEquals(res.status, 207);

  // (1) surfaced as a failed run
  const failedRuns = db.runs.filter((r) => r.status === 'failed' && r.kind === expect.kind);
  assertEquals(
    failedRuns.length,
    1,
    `the ${expect.kind} run must be recorded failed: ${JSON.stringify(db.runs)}`,
  );

  // (4) terminal, non-running, and closed
  assertEquals(
    db.runs.every((r) => r.status !== 'running' && r.finished_at != null),
    true,
    `no run may remain open: ${JSON.stringify(db.runs)}`,
  );

  // (6) the error is recorded, not swallowed.
  //
  // NOTE, deliberately not changed here: every one of these five is a failure of
  // OUR OWN DATABASE, and all of them land as `adapter_failed` — the code that
  // names the PROVIDER. The error is not swallowed (the run fails, ok is false,
  // the summary names it), but an operator reading the run row is pointed at the
  // provider while the fault is ours. Distinguishing them is a production change
  // beyond closing this test gap, so it is reported rather than made.
  assertEquals(
    typeof failedRuns[0].safe_error_code,
    'string',
    `a failed run must carry an actionable error code: ${JSON.stringify(failedRuns[0])}`,
  );


  // (5) already-completed independent work is preserved honestly
  assertEquals(
    db.runs.some((r) => r.kind === expect.survives && r.status === 'ok'),
    true,
    `the ${expect.survives} run must still be reported ok: ${JSON.stringify(db.runs)}`,
  );
  assertEquals(
    body.networks.some((n: Record<string, unknown>) => n.status === 'failed'),
    true,
    'the summary must name the failure',
  );
  assertEquals(body.failed_count, 1, 'exactly the one failure, not a blanket');

  // The RESPONSE, not only the run table, must carry the completed work: the
  // pg_cron dispatcher and any monitor read this body. A summary that reported
  // the failure and silently dropped the half that succeeded would satisfy every
  // assertion above.
  const survivor = body.networks.find((n: Record<string, unknown>) =>
    n.status !== 'failed' && n.status !== 'skipped'
  );
  assertEquals(
    survivor != null,
    true,
    `the summary must still report the ${expect.survives} work: ${JSON.stringify(body.networks)}`,
  );
  assertEquals(
    (survivor as Record<string, unknown>).fetched != null,
    true,
    'the surviving entry must carry its real counts, not just a bare status',
  );
}

Deno.test('findSource failure reaches the run, not just the ingest helper', async () => {
  const baseline = await baselineConversionCommits();
  const db = new FakeDb();
  db.networks = [{ id: 'n1', network_key: 'fixture', status: 'active' }];
  db.failSourceRead = true;
  await assertFailurePropagates(db, { kind: 'offers', survives: 'conversions' });
  // (3) an offers-side failure must not disturb money state in either
  // direction: not a partial write, and not a suppressed one. Compared by the
  // conversions actually touched, so a different mutation of equal size fails.
  assertEquals(
    db.conversionCommits,
    baseline,
    'the conversions half is neither damaged nor skipped',
  );
  // The hazard the production comment names: a failed read reported as "no such
  // offer" makes the caller INSERT A DUPLICATE offer source.
  assertEquals(
    db.ingestWrites.filter((w) => w === 'insert:affiliate_offer_sources'),
    [],
    `a failed source read must not be followed by an insert: ${db.ingestWrites.join(',')}`,
  );
});

Deno.test('alias insert failure reaches the run, not just the ingest helper', async () => {
  const baseline = await baselineConversionCommits();
  const db = new FakeDb();
  db.networks = [{ id: 'n1', network_key: 'fixture', status: 'active' }];
  // suggestAlias returns early without a bound merchant, so the insert under
  // test would never execute.
  db.programMerchantId = 'merchant-1';
  db.aliasInsertErrorCode = 'XX000';
  await assertFailurePropagates(db, { kind: 'offers', survives: 'conversions' });
  assertEquals(db.conversionCommits, baseline);
});

Deno.test('a DUPLICATE alias is still not a failure', async () => {
  // Non-vacuity for the test above, and the behaviour the code documents: a
  // duplicate suggestion is a normal outcome of a provider feed. If 23505 were
  // also fatal, the assertion above would be proving the wrong thing.
  const db = new FakeDb();
  db.networks = [{ id: 'n1', network_key: 'fixture', status: 'active' }];
  db.programMerchantId = 'merchant-1';
  db.aliasInsertErrorCode = '23505';
  // deno-lint-ignore no-explicit-any
  const res = await handleSync(authed(), () => db as any);
  assertEquals(res.status, 200);
  assertEquals((await res.json()).ok, true, 'a duplicate alias must not fail the run');
});

Deno.test('findConversion failure reaches the run, not just the ingest helper', async () => {
  // The worst of the five: a failed READ that looks like "not found" makes the
  // caller INSERT A DUPLICATE of money already recorded.
  const db = new FakeDb();
  db.networks = [{ id: 'n1', network_key: 'fixture', status: 'active' }];
  db.failConversionRead = true;
  await assertFailurePropagates(db, { kind: 'conversions', survives: 'offers' });
  // (3) above all: no duplicate money may be created off a failed read.
  assertEquals(
    db.conversionCommits,
    [],
    `a failed read must not write money: ${db.conversionCommits.join(',')}`,
  );
});

Deno.test('insertConversion failure reaches the run, not just the ingest helper', async () => {
  const db = new FakeDb();
  db.networks = [{ id: 'n1', network_key: 'fixture', status: 'active' }];
  db.failConversionInsert = true;
  await assertFailurePropagates(db, { kind: 'conversions', survives: 'offers' });
  assertEquals(db.conversionCommits, [], 'no conversion may be recorded as written');
  // The insert was genuinely reached, so "nothing committed" is not merely the
  // result of never getting there — and the count discriminates: a swallowed
  // error would carry on to the second fixture conversion and attempt twice.
  // Verified independently of the shared helper.
  assertEquals(db.conversionAttempts.length, 1, 'the insert was attempted once');
});

Deno.test('updateConversion failure reaches the run, not just the ingest helper', async () => {
  // Routed to the UPDATE branch by reporting an existing conversion. A dropped
  // update loses a settlement transition, not a click.
  const db = new FakeDb();
  db.networks = [{ id: 'n1', network_key: 'fixture', status: 'active' }];
  db.existingConversion = { id: 'conv-1', status: 'pending' };
  db.failConversionUpdate = true;
  await assertFailurePropagates(db, { kind: 'conversions', survives: 'offers' });
  assertEquals(db.conversionCommits, [], 'a failed update must not half-apply');
  // LIMITATION, stated rather than hidden: only ONE fixture conversion can take
  // the update branch (the second is `pending`, which is never applied as a
  // transition), so an attempt count of 1 is what a swallowed error would also
  // produce. For this path the discriminating assertion is the run/response
  // status in the shared helper; these two corroborate it, they do not replace
  // it. Verified by disabling the helper: the revert then goes undetected here.
  assertEquals(db.conversionAttempts.length, 1, 'the update was attempted once');
  assertEquals(
    db.conversionAttempts[0].startsWith('update:conv-1:'),
    true,
    `the UPDATE branch was taken, not insert: ${db.conversionAttempts[0]}`,
  );
});
