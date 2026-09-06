// BEHAVIOURAL handler tests for affiliate-postback.
//
// The defects this function was fixed for — a failed write permanently
// consuming an event, a claim released by the wrong request, a status
// transition swallowed as a duplicate — are all ORDERING bugs. No test that
// inspects source text can see them. These drive the real handler against a
// fake Supabase that can be told to fail at a chosen point.

import { assertEquals } from 'https://deno.land/std@0.208.0/testing/asserts.ts';
import { handlePostback } from './index.ts';
import { sha256Hex } from '../_shared/affiliate/attribution.ts';

const SECRET = 'fixture-secret';
Deno.env.set('AFFILIATE_FIXTURE_POSTBACK_SECRET', SECRET);

type Row = Record<string, unknown>;

/// A fake PostgREST surface: enough of the builder chain for this handler,
/// with injectable failures and observable state.
class FakeDb {
  receipts: Row[] = [];
  conversions: Row[] = [];
  failConversionWrite = false;
  failClaimInsert: string | null = null; // a Postgres error code
  failClaimRead = false;
  seq = 0;

  from(table: string) {
    // deno-lint-ignore no-this-alias
    const db = this;
    const rows = table === 'affiliate_webhook_receipts' ? db.receipts : db.conversions;
    const filters: Array<[string, unknown]> = [];
    const api: Record<string, unknown> = {
      insert(values: Row) {
        if (table === 'affiliate_webhook_receipts') {
          if (db.failClaimInsert) {
            return chain({ data: null, error: { code: db.failClaimInsert } });
          }
          const dup = db.receipts.some((r) =>
            r.network_key === values.network_key &&
            r.external_event_id === values.external_event_id
          );
          if (dup) return chain({ data: null, error: { code: '23505' } });
          const row = { id: `rcpt-${++db.seq}`, ...values, processed_at: null };
          db.receipts.push(row);
          return chain({ data: row, error: null });
        }
        if (db.failConversionWrite) {
          return chain({ data: null, error: { code: 'XX000' } });
        }
        const dup = db.conversions.some((c) =>
          c.network_key === values.network_key &&
          c.external_conversion_id === values.external_conversion_id
        );
        if (dup) return chain({ data: null, error: { code: '23505' } });
        db.conversions.push({ id: `conv-${++db.seq}`, ...values });
        return chain({ data: null, error: null });
      },
      select() {
        return api;
      },
      eq(col: string, val: unknown) {
        filters.push([col, val]);
        return api;
      },
      update(values: Row) {
        if (table === 'affiliate_conversions' && db.failConversionWrite) {
          return chain({ data: null, error: { code: 'XX000' } });
        }
        // PostgREST OMITS undefined keys and writes explicit nulls. Object.assign
        // would copy undefined over a stored value, which real PostgREST never
        // does — modelling that wrongly would have made this harness "prove" a
        // bug the production path does not have.
        const patch: Row = {};
        for (const [k, v] of Object.entries(values)) {
          if (v !== undefined) patch[k] = v;
        }
        // LAZY. `.eq()` is chained AFTER update(), so applying here would write
        // EVERY row and hide a missing or wrong filter — precisely the class of
        // bug the release/claim tests exist to catch.
        return deferred(() => {
          for (const r of match()) Object.assign(r, patch);
        });
      },
      delete() {
        // Lazy for the same reason. Eager deletion here removes every receipt
        // regardless of the filter, which would let the release test pass even
        // if the handler deleted the wrong claim.
        return deferred(() => {
          for (const r of match()) {
            const i = rows.indexOf(r);
            if (i >= 0) rows.splice(i, 1);
          }
        });
      },
      maybeSingle() {
        if (table === 'affiliate_webhook_receipts' && db.failClaimRead) {
          return Promise.resolve({ data: null, error: { code: 'XX000' } });
        }
        const m = match();
        return Promise.resolve({ data: m[0] ?? null, error: null });
      },
      single() {
        const m = match();
        return Promise.resolve({ data: m[0] ?? null, error: null });
      },
    };
    function match() {
      return rows.filter((r) => filters.every(([c, v]) => r[c] === v));
    }
    /// A builder whose mutation runs only when the statement is awaited, so the
    /// filters chained after update()/delete() are the ones that apply.
    function deferred(apply: () => void) {
      const run = () => {
        apply();
        return { data: null, error: null };
      };
      const builder: Record<string, unknown> = {
        eq: (c: string, v: unknown) => { filters.push([c, v]); return builder; },
        select: () => builder,
        single: () => Promise.resolve(run()),
        maybeSingle: () => Promise.resolve(run()),
        // deno-lint-ignore no-explicit-any
        then: (ok: any, err: any) => Promise.resolve(run()).then(ok, err),
      };
      return builder;
    }
    function chain(result: unknown) {
      const p = Promise.resolve(result) as unknown as Record<string, unknown>;
      (p as { select?: unknown }).select = () => p;
      (p as { maybeSingle?: unknown }).maybeSingle = () => Promise.resolve(result);
      (p as { single?: unknown }).single = () => Promise.resolve(result);
      (p as { eq?: unknown }).eq = (c: string, v: unknown) => {
        filters.push([c, v]);
        return p;
      };
      return p;
    }
    return api;
  }
}

async function post(db: FakeDb, body: Record<string, unknown>) {
  const raw = JSON.stringify(body);
  const sig = await sha256Hex(SECRET + raw);
  // The network is a QUERY PARAMETER, not a header.
  const req = new Request('https://x/affiliate-postback?network=fixture', {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'x-qirsh-signature': sig,
    },
    body: raw,
  });
  // deno-lint-ignore no-explicit-any
  return await handlePostback(req, () => db as any);
}

const EVENT = (over: Record<string, unknown> = {}) => ({
  event_id: 'evt-1',
  conversion_id: 'conv-ext-1',
  status: 'pending',
  order_amount_minor: 10000,
  order_currency: 'SAR',
  commission_amount_minor: 500,
  commission_currency: 'SAR',
  occurred_at: '2026-09-06T00:00:00Z',
  ...over,
});

Deno.test('first successful postback writes the conversion and marks the receipt', async () => {
  const db = new FakeDb();
  const res = await post(db, EVENT());
  assertEquals(res.status, 200);
  assertEquals(db.conversions.length, 1);
  assertEquals(db.receipts.length, 1);
  assertEquals(db.receipts[0].result_code, 'applied');
  assertEquals(typeof db.receipts[0].processed_at, 'string');
});

Deno.test('an exact duplicate is a 200 and writes nothing new', async () => {
  const db = new FakeDb();
  await post(db, EVENT());
  const res = await post(db, EVENT());
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { ok: true, duplicate: true });
  assertEquals(db.conversions.length, 1, 'no second conversion');
  assertEquals(db.receipts.length, 1);
});

Deno.test('a FAILED conversion write releases the claim and asks for a retry', async () => {
  // THE defect: this used to mark the receipt processed and return 200, so the
  // provider never retried and the conversion was lost forever.
  const db = new FakeDb();
  db.failConversionWrite = true;
  const res = await post(db, EVENT());
  assertEquals(res.status, 503, 'the provider must be told to retry');
  assertEquals(db.conversions.length, 0);
  assertEquals(db.receipts.length, 0, 'the claim must be RELEASED, not consumed');
});

Deno.test('a failed UPDATE of an existing conversion also releases the claim', async () => {
  // The insert path and the update path fail differently and were fixed
  // together, but only the insert path was covered: this drives a SECOND
  // delivery for a conversion that already exists, so the write under test is
  // an UPDATE. Losing a status transition loses the settlement, not the click.
  const db = new FakeDb();
  assertEquals((await post(db, EVENT())).status, 200);
  assertEquals(db.conversions.length, 1);
  const before = { ...db.conversions[0] };

  db.failConversionWrite = true;
  const res = await post(db, EVENT({ event_id: 'evt-2', status: 'approved' }));
  assertEquals(res.status, 503, 'the provider must be told to retry the update');
  assertEquals(db.receipts.length, 1, 'only the FIRST delivery keeps its claim');
  assertEquals(
    db.conversions[0].status,
    before.status,
    'a failed update must not half-apply',
  );

  // Non-vacuity: with the write restored, the same delivery lands.
  db.failConversionWrite = false;
  assertEquals((await post(db, EVENT({ event_id: 'evt-2', status: 'approved' }))).status, 200);
  assertEquals(db.conversions[0].status, 'approved', 'the retry applies the transition');
});

Deno.test('the retry after a failed write succeeds', async () => {
  const db = new FakeDb();
  db.failConversionWrite = true;
  assertEquals((await post(db, EVENT())).status, 503);
  db.failConversionWrite = false;
  const res = await post(db, EVENT());
  assertEquals(res.status, 200);
  assertEquals(db.conversions.length, 1, 'the conversion is recovered');
});

Deno.test('an UNPROCESSED claim resumes instead of reporting duplicate', async () => {
  // A previous attempt died between claiming and writing. Reporting duplicate
  // here is how a real conversion gets dropped with a 200.
  const db = new FakeDb();
  db.receipts.push({
    id: 'rcpt-orphan',
    network_key: 'fixture',
    external_event_id: 'evt-1',
    payload_hash: 'x',
    processed_at: null,
  });
  const res = await post(db, EVENT());
  assertEquals(res.status, 200);
  assertEquals(db.conversions.length, 1, 'the stalled event is completed');
  // The resumed claim must also be CLOSED. Left unprocessed it would resume
  // again on every future delivery, re-running the write path forever.
  assertEquals(db.receipts.length, 1, 'the orphan claim is reused, not duplicated');
  assertEquals(
    typeof db.receipts[0].processed_at,
    'string',
    'the resumed claim must be marked processed',
  );
});

Deno.test('a non-unique claim error does NOT resume claimless', async () => {
  // Any error other than 23505 previously fell through to the resume path and
  // wrote a conversion holding no claim at all.
  const db = new FakeDb();
  db.failClaimInsert = 'XX000';
  const res = await post(db, EVENT());
  assertEquals(res.status, 503);
  assertEquals(db.conversions.length, 0, 'nothing written without a claim');
});

Deno.test('a claim READ failure does not destroy a legitimate replay guard', async () => {
  const db = new FakeDb();
  await post(db, EVENT());          // processed
  db.failClaimRead = true;
  const res = await post(db, EVENT());
  assertEquals(res.status, 503);
  assertEquals(db.receipts.length, 1, 'the processed receipt survives');
});

Deno.test('a status transition is applied, not swallowed as a duplicate', async () => {
  // The event_id fallback made every status change for one conversion share a
  // receipt key, so `approved` was swallowed and the conversion stuck pending.
  const db = new FakeDb();
  await post(db, EVENT({ event_id: undefined, status: 'pending' }));
  await post(db, EVENT({ event_id: undefined, status: 'approved' }));
  assertEquals(db.conversions.length, 1);
  assertEquals(db.conversions[0].status, 'approved');
});

Deno.test('approved does not regress to pending', async () => {
  const db = new FakeDb();
  await post(db, EVENT({ event_id: 'e1', status: 'pending' }));
  await post(db, EVENT({ event_id: 'e2', status: 'approved' }));
  await post(db, EVENT({ event_id: 'e3', status: 'pending' }));
  assertEquals(db.conversions[0].status, 'approved', 'a stale pending must not demote');
});

Deno.test('a terminal-negative state stays sticky', async () => {
  const db = new FakeDb();
  await post(db, EVENT({ event_id: 'e1', status: 'pending' }));
  await post(db, EVENT({ event_id: 'e2', status: 'returned' }));
  await post(db, EVENT({ event_id: 'e3', status: 'approved' }));
  assertEquals(db.conversions[0].status, 'returned', 'a clawback is not revived');
});

Deno.test('a clawback with no amounts does not erase the recorded commission', async () => {
  // PostgREST writes an explicit null; passing absent money through blanked the
  // commission of the conversion being clawed back.
  const db = new FakeDb();
  await post(db, EVENT({ event_id: 'e1', status: 'pending' }));
  assertEquals(db.conversions[0].commission_amount_minor, 500);
  await post(db, EVENT({
    event_id: 'e2',
    status: 'returned',
    order_amount_minor: undefined,
    commission_amount_minor: undefined,
    order_currency: undefined,
    commission_currency: undefined,
  }));
  assertEquals(db.conversions[0].status, 'returned');
  assertEquals(db.conversions[0].commission_amount_minor, 500,
    'absent means unchanged, never zero');
});

Deno.test('a racing duplicate cannot create a second conversion', async () => {
  const db = new FakeDb();
  const [a, b] = await Promise.all([post(db, EVENT()), post(db, EVENT())]);
  assertEquals(db.conversions.length, 1, 'exactly one conversion');
  const codes = [a.status, b.status].sort();
  assertEquals(codes.every((c) => c === 200 || c === 503), true, `got ${codes}`);
  // The winner's receipt must survive the race. Release used to delete by
  // (network_key, external_event_id), so the loser's cleanup destroyed the
  // WINNER's claim and the event became replayable.
  assertEquals(db.receipts.length, 1, 'the winner keeps its claim');
});

Deno.test('a release deletes only the claim THIS request owns', async () => {
  // Release is scoped to the claim id the request holds. Scoping it to the
  // event key instead deletes a concurrent delivery's claim as well — which is
  // exactly how a replay guard gets erased by an unrelated failure.
  const db = new FakeDb();
  assertEquals((await post(db, EVENT({ event_id: 'keep-me' }))).status, 200);
  assertEquals(db.receipts.length, 1);

  db.failConversionWrite = true;
  const res = await post(db, EVENT({
    event_id: 'lose-me',
    conversion_id: 'conv-ext-2',
  }));
  assertEquals(res.status, 503);
  assertEquals(db.receipts.length, 1, 'the unrelated claim must survive');
  assertEquals(
    db.receipts[0].external_event_id,
    'keep-me',
    `the surviving claim is the untouched one: ${JSON.stringify(db.receipts)}`,
  );
});
