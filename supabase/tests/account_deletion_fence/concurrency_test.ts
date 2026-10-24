// concurrency_test.ts — real-database schedules for the account-deletion fence.
// It needs the disposable loopback stack, with fence.sql (migration 0117) applied. It talks to PostgreSQL through `psql`
// subprocesses (one long-lived process per session) so it has no driver
// dependency, and to the real Auth/Storage HTTP APIs on loopback.
//
// Env (loopback only, synthetic): FENCE_DB_URL, FENCE_API_URL, FENCE_SERVICE_KEY,
// FENCE_ANON_KEY. Without FENCE_DB_URL every test is ignored (never "passes").
import { assert, assertEquals, assertStringIncludes } from 'https://deno.land/std@0.224.0/assert/mod.ts';

const DB = Deno.env.get('FENCE_DB_URL') ?? '';
const API = Deno.env.get('FENCE_API_URL') ?? '';
const SERVICE_KEY = Deno.env.get('FENCE_SERVICE_KEY') ?? '';
const ANON_KEY = Deno.env.get('FENCE_ANON_KEY') ?? '';
const enabled = DB !== '' && /^postgres(ql)?:\/\/[^@]*@(127\.0\.0\.1|localhost|\[::1\])[:/]/.test(DB);

/** One psql process == one database session. stderr is merged into stdout. */
class Session {
  #proc: Deno.ChildProcess;
  #w: WritableStreamDefaultWriter<Uint8Array>;
  #r: ReadableStreamDefaultReader<Uint8Array>;
  #buf = '';
  #n = 0;
  readonly enc = new TextEncoder();
  readonly dec = new TextDecoder();

  constructor(readonly name: string) {
    const cmd = new Deno.Command('sh', {
      args: ['-c', `exec psql -X -q -A -t -v VERBOSITY=verbose -v ON_ERROR_STOP=0 "$FENCE_DB_URL" 2>&1`],
      env: { FENCE_DB_URL: DB },
      stdin: 'piped',
      stdout: 'piped',
    });
    this.#proc = cmd.spawn();
    this.#w = this.#proc.stdin.getWriter();
    this.#r = this.#proc.stdout.getReader();
  }

  /** Sends SQL and returns everything printed until the sentinel (or times out). */
  async run(sql: string, timeoutMs = 20_000): Promise<string> {
    const tag = `__DONE_${this.name}_${++this.#n}__`;
    await this.#w.write(this.enc.encode(`${sql}\n\\echo ${tag}\n`));
    const deadline = Date.now() + timeoutMs;
    while (!this.#buf.includes(tag)) {
      const left = deadline - Date.now();
      if (left <= 0) throw new Error(`session ${this.name} timed out waiting for ${tag}`);
      const chunk = await Promise.race([
        this.#r.read(),
        new Promise<null>((res) => setTimeout(() => res(null), left)),
      ]);
      if (chunk === null) throw new Error(`session ${this.name} timed out waiting for ${tag}`);
      if (chunk.done) throw new Error(`session ${this.name} closed`);
      this.#buf += this.dec.decode(chunk.value);
    }
    const i = this.#buf.indexOf(tag);
    const out = this.#buf.slice(0, i);
    this.#buf = this.#buf.slice(i + tag.length);
    return out.trim();
  }

  /** Starts SQL that may block; resolves later with its output. */
  start(sql: string, timeoutMs = 20_000): Promise<string> {
    return this.run(sql, timeoutMs);
  }

  async close() {
    try {
      await this.#w.write(this.enc.encode('\\q\n'));
      await this.#w.close();
    } catch { /* already gone */ }
    try { await this.#proc.status; } catch { /* ignore */ }
  }
}

async function withSessions<T>(names: string[], fn: (s: Record<string, Session>) => Promise<T>): Promise<T> {
  const s: Record<string, Session> = {};
  for (const n of names) s[n] = new Session(n);
  try {
    return await fn(s);
  } finally {
    await Promise.all(Object.values(s).map((x) => x.close()));
  }
}

const uuid = () => crypto.randomUUID();

/** Real Auth admin API: creates a synthetic confirmed user. */
async function createUser(): Promise<{ id: string; email: string; password: string }> {
  const email = `fence-${crypto.randomUUID()}@example.invalid`;
  const password = crypto.randomUUID() + 'Aa1!';
  const res = await fetch(`${API}/auth/v1/admin/users`, {
    method: 'POST',
    headers: { apikey: SERVICE_KEY, authorization: `Bearer ${SERVICE_KEY}`, 'content-type': 'application/json' },
    body: JSON.stringify({ email, password, email_confirm: true }),
  });
  assertEquals(res.status, 200, 'synthetic user creation');
  const body = await res.json();
  // A fresh Auth user owns no user_settings row, so every schedule below that UPDATEs user_settings would match zero rows
  // and fire no row guard at all (vacuous). Seed exactly one row (before any acceptance) so the guards actually run.
  const seed = new Session('seed');
  try {
    const out = await seed.run(`insert into public.user_settings(user_id, local_id) values ('${body.id}', 'fence-settings');`);
    assert(!out.includes('ERROR'), `user_settings seed failed: ${out}`);
  } finally {
    await seed.close();
  }
  return { id: body.id as string, email, password };
}

async function signIn(email: string, password: string): Promise<string> {
  const res = await fetch(`${API}/auth/v1/token?grant_type=password`, {
    method: 'POST',
    headers: { apikey: ANON_KEY, 'content-type': 'application/json' },
    body: JSON.stringify({ email, password }),
  });
  assertEquals(res.status, 200);
  return (await res.json()).access_token as string;
}

/** SET LOCAL ROLE + JWT claims so a session behaves like a PostgREST caller. */
const asUser = (uid: string) =>
  `set local role authenticated; select set_config('request.jwt.claims', '{"sub":"${uid}","role":"authenticated"}', true);`;

/** Seeds an acceptable challenge (via the service-role issuer RPC) + reserved material. A direct INSERT into
 *  account_fence.deletion_challenge is impossible by design: no role but the narrow owner has any privilege on it. */
async function seedAcceptance(admin: Session, uid: string, tag: string) {
  const ref = `enc:${tag}-${crypto.randomUUID().replaceAll('-', '')}`;
  const issuedOut = await admin.run(`select public.account_deletion_issue_challenge('${uid}');`);
  const line = issuedOut.split('\n').find((l) => l.startsWith('{'));
  assert(line !== undefined, `challenge issuance failed: ${issuedOut}`);
  const issued = JSON.parse(line!);
  assertEquals(issued.outcome, 'issued', issuedOut);
  const reserved = await admin.run(`select public.account_deletion_reserve_material('${ref}', 'sealed');`);
  assert(!reserved.includes('ERROR'), reserved);
  return {
    ref,
    accept: (attempt: string) =>
      `select public.account_deletion_accept('scope-${tag}', '${uid}', '${issued.challenge_id}', ${issued.expires_at_ms}, 'rh-${tag}', '${ref}', '${attempt}');`,
  };
}

const t = (name: string, fn: () => Promise<void>) =>
  Deno.test({ name: `fence: ${name}`, ignore: !enabled, sanitizeOps: false, sanitizeResources: false, fn });

// ── Schedules ────────────────────────────────────────────────────────────────

t('writer first: acceptance waits for the in-flight writer, then later writers see QD001', async () => {
  const u = await createUser();
  await withSessions(['admin', 'writer', 'acceptor', 'late'], async (s) => {
    const seed = await seedAcceptance(s.admin, u.id, 'wf');
    await s.writer.run(`begin; ${asUser(u.id)} update public.user_settings set updated_at = now() where user_id = '${u.id}';`);
    const started = Date.now();
    const accept = s.acceptor.start(seed.accept('attempt-wf-1'));
    await new Promise((r) => setTimeout(r, 750));
    // acceptance has not returned while the writer holds the gate
    await s.writer.run('commit;');
    const out = await accept;
    assertStringIncludes(out, 'accepted');
    assert(Date.now() - started >= 700, 'acceptance should have waited for the writer');
    const late = await s.late.run(`begin; ${asUser(u.id)} update public.user_settings set updated_at = now() where user_id = '${u.id}'; rollback;`);
    assertStringIncludes(late, 'QD001');
  });
});

t('acceptance first: a later writer is rejected with QD001 and nothing is written', async () => {
  const u = await createUser();
  await withSessions(['admin', 'acceptor', 'writer'], async (s) => {
    const seed = await seedAcceptance(s.admin, u.id, 'af');
    assertStringIncludes(await s.acceptor.run(seed.accept('attempt-af-1')), 'accepted');
    const out = await s.writer.run(`begin; ${asUser(u.id)} update public.user_settings set updated_at = now() where user_id = '${u.id}'; rollback;`);
    assertStringIncludes(out, 'QD001');
  });
});

t('late row guard never waits: contention fails fast with 55P03 and releases the tuple', async () => {
  const u = await createUser();
  await withSessions(['holder', 'writer', 'other'], async (s) => {
    // holder owns the gate (an open ordinary writer transaction)
    await s.holder.run(`begin; select account_fence.admit('${u.id}');`);
    const t0 = Date.now();
    const out = await s.writer.run(`begin; ${asUser(u.id)} update public.user_settings set updated_at = now() where user_id = '${u.id}'; rollback;`);
    assertStringIncludes(out, '55P03');
    assert(Date.now() - t0 < 3000, 'must not wait on the gate');
    await s.holder.run('rollback;');
    // the tuple was not left locked by the loser
    const ok = await s.other.run(`update public.user_settings set updated_at = now() where user_id = '${u.id}' returning 1;`);
    assert(!ok.includes('ERROR'));
  });
});

t('target-row-before-trigger vs gate-before-state: bounded completion, no deadlock', async () => {
  const u = await createUser();
  await withSessions(['admin', 'acceptor', 'direct', 'cas'], async (s) => {
    const seed = await seedAcceptance(s.admin, u.id, 'ord');
    await s.direct.run(`begin; ${asUser(u.id)} select 1 from public.user_settings where user_id = '${u.id}' for update;`);
    const accept = s.acceptor.start(seed.accept('attempt-ord-1'));
    const casOut = await s.cas.run(`begin; ${asUser(u.id)} select public.sync_lock_epoch(); rollback;`, 10_000);
    // either serialised behind acceptance or rejected quickly; never a hang or 40P01
    assert(!casOut.includes('40P01'), 'deadlock detected');
    await s.direct.run('rollback;');
    await accept;
  });
});

t('erasure: leased purge succeeds, context is gone afterwards, and a client GUC grants nothing', async () => {
  const u = await createUser();
  await withSessions(['admin', 'svc', 'client'], async (s) => {
    const seed = await seedAcceptance(s.admin, u.id, 'er');
    await s.admin.run(seed.accept('attempt-er-1'));
    const claim = await s.svc.run(`select public.account_deletion_claim_lease('w1', 60000, null);`);
    const lease = JSON.parse(claim.split('\n').find((l) => l.startsWith('{'))!);
    const { job_id, token, generation } = lease.lease;
    for (const stage of ['apple_revoke', 'storage_sweep', 'sql_purge']) {
      await s.svc.run(`select public.account_deletion_begin_step('${job_id}','${token}',${generation},'${stage}');`);
      if (stage !== 'sql_purge') {
        await s.svc.run(`select public.account_deletion_complete_step('${job_id}','${token}',${generation},'${stage}');`);
      }
    }
    const purge = await s.svc.run(`select public.account_deletion_purge('${job_id}','${token}',${generation});`);
    assertStringIncludes(purge, 'done');
    assertEquals(await s.admin.run(`select count(*) from account_fence.erasure_ctx;`), '0');
    // forged context attempts
    const forged = await s.client.run(`begin; ${asUser(u.id)} set local app.erasure = 'on'; update public.user_settings set updated_at = now() where user_id = '${u.id}'; rollback;`);
    assertStringIncludes(forged, 'QD001');
    const direct = await s.client.run(`set role service_role; select public.purge_user_data('${u.id}');`);
    assertStringIncludes(direct, 'permission denied');
  });
});

t('purge with a stale lease or wrong step is refused', async () => {
  const u = await createUser();
  await withSessions(['admin', 'svc'], async (s) => {
    const seed = await seedAcceptance(s.admin, u.id, 'st');
    await s.admin.run(seed.accept('attempt-st-1'));
    const out = await s.svc.run(`select public.account_deletion_purge('${uuid()}','${uuid()}',1);`);
    assertStringIncludes(out, 'QD010');
  });
});

t('Auth-absent stale JWT: writes are rejected with QD002', async () => {
  const u = await createUser();
  await withSessions(['admin', 'writer'], async (s) => {
    await s.admin.run(`delete from auth.users where id = '${u.id}';`);
    const out = await s.writer.run(`begin; ${asUser(u.id)} select public.sync_lock_epoch(); rollback;`);
    assertStringIncludes(out, 'QD002');
  });
});

t('Auth ON DELETE SET NULL cascade passes the guard (referrals.referred_user_id)', async () => {
  const referrer = await createUser();
  const referred = await createUser();
  await withSessions(['admin'], async (s) => {
    const ins = await s.admin.run(
      `insert into public.referral_codes(user_id, code) values ('${referrer.id}', 'ABCDEFGH') on conflict do nothing;` +
        `insert into public.referrals(referrer_user_id, referred_user_id, referral_code, status, qualified_at) values ('${referrer.id}','${referred.id}','ABCDEFGH','qualified', now());`,
    );
    assert(!ins.includes('ERROR'), ins);
    const del = await s.admin.run(`delete from auth.users where id = '${referred.id}';`);
    assert(!del.includes('ERROR'), del);
    assertEquals(await s.admin.run(`select referred_user_id is null from public.referrals where referrer_user_id = '${referrer.id}';`), 't');
  });
});

t('duplicate acceptance of the same scope returns the same job; a fenced attempt can never commit', async () => {
  const u = await createUser();
  await withSessions(['admin', 'a', 'b'], async (s) => {
    const seed = await seedAcceptance(s.admin, u.id, 'dup');
    const first = await s.a.run(seed.accept('attempt-dup-1'));
    const second = await s.b.run(seed.accept('attempt-dup-2'));
    assertStringIncludes(first, 'accepted');
    assertStringIncludes(second, 'duplicate');
    const fence = await s.admin.run(`select public.account_deletion_fence_attempt('attempt-never-ran');`);
    assertStringIncludes(fence, '"fenced": true');
    const late = await s.a.run(seed.accept('attempt-never-ran'));
    assertStringIncludes(late, 'fenced');
  });
});

for (const [retryable, expected] of [[true, 'committed:true'], [false, 'disposed:false']] as const) {
  t(`F4: record_failure retryable=${retryable} leaves Apple material ${expected}`, async () => {
    const u = await createUser();
    await withSessions(['admin', 'svc'], async (s) => {
      const seed = await seedAcceptance(s.admin, u.id, retryable ? 'f4r' : 'f4t');
      await s.admin.run(seed.accept(`attempt-f4-${retryable}`));
      const probe = `select state || ':' || (ciphertext is not null) from account_fence.deletion_material where ref = '${seed.ref}';`;
      assertEquals(await s.admin.run(probe), 'committed:true');
      const claim = await s.svc.run(`select public.account_deletion_claim_lease('w1', 60000, null);`);
      const lease = JSON.parse(claim.split('\n').find((l) => l.startsWith('{'))!);
      const { job_id, token, generation } = lease.lease;
      const out = await s.svc.run(
        `select public.account_deletion_record_failure('${job_id}','${token}',${generation},'apple_revoke','apple_rejected',${retryable},0);`,
      );
      assert(!out.includes('ERROR'), out);
      assertEquals(await s.admin.run(probe), expected);
    });
  });
}

// ── Real Auth / Storage API schedules ────────────────────────────────────────

t('Storage: an authenticated upload after acceptance is refused by the write policy', async () => {
  const u = await createUser();
  const jwt = await signIn(u.email, u.password);
  await withSessions(['admin'], async (s) => {
    const seed = await seedAcceptance(s.admin, u.id, 'sto');
    await s.admin.run(seed.accept('attempt-sto-1'));
  });
  const res = await fetch(`${API}/storage/v1/object/backups/${u.id}/blob.bin`, {
    method: 'POST',
    headers: { apikey: ANON_KEY, authorization: `Bearer ${jwt}`, 'content-type': 'application/octet-stream' },
    body: new Uint8Array([1, 2, 3]),
  });
  assert(res.status === 400 || res.status === 403, `expected a policy refusal, got ${res.status}`);
});

t('Auth admin delete after purge: the stale JWT can no longer write (QD002)', async () => {
  const u = await createUser();
  await withSessions(['admin', 'writer'], async (s) => {
    const del = await fetch(`${API}/auth/v1/admin/users/${u.id}`, {
      method: 'DELETE',
      headers: { apikey: SERVICE_KEY, authorization: `Bearer ${SERVICE_KEY}` },
    });
    assert(del.status === 200, `auth delete returned ${del.status}`);
    const out = await s.writer.run(`begin; ${asUser(u.id)} select public.sync_lock_epoch(); rollback;`);
    assertStringIncludes(out, 'QD002');
  });
});
