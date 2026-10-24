// Tests for the immediate-deletion adapter. Every port is a fake: the in-memory
// backend below models the CONTRACT of the draft SQL RPCs (supabase/drafts/
// account_deletion_fence/fence.sql). It cannot prove SQL atomicity, locking,
// RLS or any real Apple/Storage/Auth behaviour; see DECISIONS.md.
import { assert, assertEquals, assertFalse, assertRejects, assertStringIncludes } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import {
  type AppleGateway,
  buildAccountDeletionCoordinator,
  createAccountDeletionAdapter,
  type AdapterPorts,
  type RpcResult,
} from './account_deletion_adapter.ts';
import { type StorageLike, type StorageObject } from './storage_erasure.ts';
import { DELETION_STAGES } from './account_deletion_coordinator.ts';
import { createDeleteAccountHandler } from '../delete-account-immediate/handler.ts';

const UID = '11111111-1111-4111-8111-111111111111';
const OTHER_UID = '22222222-2222-4222-8222-222222222222';
const SECRET = 'A'.repeat(43);
const SECRET_2 = 'B'.repeat(43);
const CHALLENGE = 'challenge-0001';
const CHALLENGE_2 = 'challenge-0002';
const LEAK = 'sensitive-provider-text-do-not-leak';

type Job = {
  jobId: string;
  uid: string;
  attemptId: string;
  steps: string[];
  ref: string | null;
  attempts: number;
  state: string;
  token: string | null;
  generation: number;
  leaseExpired: boolean;
  retainedUntilMs: number | null;
  receipts: Set<string>;
};

// ── In-memory model of the RPC contract ──────────────────────────────────────
class FakeBackend {
  jobs = new Map<string, Job>();
  scopes = new Map<string, { jobId: string; receiptHash: string }>();
  materials = new Map<string, { state: 'reserved' | 'committed' | 'disposed'; cipher: string }>();
  tombstones = new Set<string>();
  receipts = new Map<string, string>();
  calls: Array<{ fn: string; args: Record<string, unknown> }> = [];
  // failure injection
  throwOn = new Set<string>(); // RPC rejects before executing
  lostResponse = new Set<string>(); // RPC executes, then the response is lost
  errorOn = new Map<string, string>(); // RPC returns a PostgREST error with this code
  private seq = 0;

  names() {
    return this.calls.map((c) => c.fn);
  }

  async rpc(fn: string, args: Record<string, unknown>): Promise<RpcResult> {
    this.calls.push({ fn, args });
    if (this.throwOn.has(fn)) throw new Error(`network ${LEAK}`);
    const code = this.errorOn.get(fn);
    if (code) return { data: null, error: { code, message: LEAK } };
    const data = this.exec(fn, args);
    if (this.lostResponse.has(fn)) throw new Error(`timeout ${LEAK}`);
    return { data, error: null };
  }

  private jobFor(args: Record<string, unknown>): Job | null {
    const j = this.jobs.get(String(args.p_job_id));
    if (!j || j.token !== args.p_lease_token || j.generation !== args.p_generation || j.leaseExpired) return null;
    return j;
  }

  private exec(fn: string, a: Record<string, unknown>): unknown {
    switch (fn) {
      case 'account_deletion_reserve_material':
        this.materials.set(String(a.p_ref), { state: 'reserved', cipher: String(a.p_ciphertext) });
        return { ok: true };
      case 'account_deletion_dispose_material': {
        const m = this.materials.get(String(a.p_ref));
        if (!m) return { status: 'kept_unconfirmed' };
        if (m.state === 'committed') return { status: 'kept_referenced' };
        m.state = 'disposed';
        m.cipher = '';
        return { status: 'disposed' };
      }
      case 'account_deletion_read_material': {
        const m = this.materials.get(String(a.p_ref));
        return m && m.state === 'committed' ? m.cipher : null;
      }
      case 'account_deletion_find_accepted': {
        const s = this.scopes.get(String(a.p_scope_key));
        return s ? { job_id: s.jobId, receipt_hash: s.receiptHash } : null;
      }
      case 'account_deletion_accept': {
        const attempt = String(a.p_attempt_id);
        if (this.tombstones.has(attempt)) return { outcome: 'challenge_expired' };
        const scope = this.scopes.get(String(a.p_scope_key));
        if (scope) {
          return scope.receiptHash === a.p_receipt_hash
            ? { outcome: 'duplicate', job_id: scope.jobId }
            : { outcome: 'idempotency_conflict' };
        }
        const existing = [...this.jobs.values()].find((j) => j.uid === a.p_uid && j.state !== 'completed');
        if (existing) {
          existing.receipts.add(String(a.p_receipt_hash));
          this.receipts.set(String(a.p_receipt_hash), existing.jobId);
          this.scopes.set(String(a.p_scope_key), { jobId: existing.jobId, receiptHash: String(a.p_receipt_hash) });
          return { outcome: 'already_pending', job_id: existing.jobId };
        }
        const m = this.materials.get(String(a.p_apple_material_ref));
        if (!m || m.state !== 'reserved') return { outcome: 'challenge_expired' };
        m.state = 'committed';
        const jobId = `job-${++this.seq}`;
        this.jobs.set(jobId, {
          jobId, uid: String(a.p_uid), attemptId: attempt, steps: [], ref: String(a.p_apple_material_ref),
          attempts: 0, state: 'accepted', token: null, generation: 0, leaseExpired: false,
          retainedUntilMs: null, receipts: new Set([String(a.p_receipt_hash)]),
        });
        this.receipts.set(String(a.p_receipt_hash), jobId);
        this.scopes.set(String(a.p_scope_key), { jobId, receiptHash: String(a.p_receipt_hash) });
        return { outcome: 'accepted', job_id: jobId };
      }
      case 'account_deletion_fence_attempt': {
        const attempt = String(a.p_attempt_id);
        const job = [...this.jobs.values()].find((j) => j.attemptId === attempt);
        if (job) return { fenced: false, outcome: 'accepted', job_id: job.jobId };
        this.tombstones.add(attempt);
        return { fenced: true };
      }
      case 'account_deletion_claim_lease': {
        const j = [...this.jobs.values()].find((x) =>
          x.state !== 'completed' && x.state !== 'failed' && (!a.p_job_id || x.jobId === a.p_job_id)
        );
        if (!j) return null;
        j.generation += 1;
        j.token = `tok-${j.generation}`;
        j.leaseExpired = false;
        j.state = 'running';
        return {
          lease: { job_id: j.jobId, token: j.token, generation: j.generation },
          job: {
            job_id: j.jobId, uid: j.uid, completed_steps: [...j.steps],
            apple_material_ref: j.steps.length ? null : j.ref, attempts: j.attempts,
          },
        };
      }
      case 'account_deletion_heartbeat':
        return this.jobFor(a) ? { ok: true } : { ok: false, reason: 'lease_lost' };
      case 'account_deletion_begin_step': {
        const j = this.jobFor(a);
        if (!j) return { ok: false, reason: 'lease_lost' };
        const expected = DELETION_STAGES[j.steps.length];
        return a.p_stage === expected ? { ok: true } : { ok: false, reason: 'out_of_order' };
      }
      case 'account_deletion_complete_step': {
        const j = this.jobFor(a);
        if (!j) return { ok: false, reason: 'lease_lost' };
        j.steps.push(String(a.p_stage));
        if (a.p_stage === 'apple_revoke') {
          const m = this.materials.get(j.ref!);
          if (m) { m.state = 'disposed'; m.cipher = ''; }
          j.ref = null;
        }
        return { ok: true };
      }
      case 'account_deletion_record_failure': {
        const j = this.jobFor(a);
        if (!j) return { ok: false, reason: 'lease_lost' };
        j.attempts += 1;
        j.state = a.p_retryable ? 'retryable' : 'failed';
        return { ok: true };
      }
      case 'account_deletion_complete_job': {
        const j = this.jobFor(a);
        if (!j) return { ok: false, reason: 'lease_lost' };
        if (j.steps.length !== DELETION_STAGES.length) return { ok: false, reason: 'incomplete_steps' };
        j.state = 'completed';
        j.retainedUntilMs = 1_000_000 + Number(a.p_receipt_retention_ms);
        return { ok: true };
      }
      case 'account_deletion_get_receipt': {
        const id = this.receipts.get(String(a.p_receipt_hash));
        const j = id ? this.jobs.get(id) : undefined;
        if (!j) return null;
        return j.state === 'completed'
          ? { state: 'completed', retained_until_ms: j.retainedUntilMs }
          : { state: j.state };
      }
      case 'account_deletion_purge': {
        const j = this.jobFor(a);
        if (!j) throw new Error('lease');
        return { status: 'done' };
      }
    }
    throw new Error(`unknown rpc ${fn}`);
  }
}

class FakeStorage implements StorageLike {
  objects = new Set<string>();
  listCalls = 0;
  failList = false;
  failRemove = false;
  from(_bucket: string) {
    return {
      list: (path: string, opts?: { limit?: number; offset?: number }) => {
        this.listCalls++;
        if (this.failList) return Promise.resolve({ data: null, error: { message: LEAK } });
        const names: StorageObject[] = [...this.objects]
          .filter((p) => p.startsWith(`${path}/`) && !p.slice(path.length + 1).includes('/'))
          .map((p) => ({ name: p.slice(path.length + 1), id: p }));
        const off = opts?.offset ?? 0;
        return Promise.resolve({ data: names.slice(off, off + (opts?.limit ?? 100)), error: null });
      },
      remove: (paths: string[]) => {
        if (this.failRemove) return Promise.resolve({ data: null, error: { message: LEAK } });
        for (const p of paths) this.objects.delete(p);
        return Promise.resolve({ data: null, error: null });
      },
    };
  }
}

type Harness = ReturnType<typeof harness>;

function harness(over: Partial<AdapterPorts> = {}) {
  const backend = new FakeBackend();
  const storage = new FakeStorage();
  storage.objects.add(`${UID}/backup.bin`);
  const order: string[] = [];
  const apple = {
    authorizeCalls: 0,
    revokeCalls: 0,
    revokeResult: 'revoked_verified' as 'revoked_verified' | 'retryable' | 'failed',
    authorizeResult: null as null | { status: string },
    async authorize(input: { uid: string; challengeId: string; challengeResponse: string }) {
      this.authorizeCalls++;
      assertEquals(input.uid, UID);
      if (this.authorizeResult) return this.authorizeResult as never;
      return { status: 'ok' as const, refreshToken: `rt-${this.authorizeCalls}`, challengeExpiresAtMs: 9_999_999 };
    },
    async revoke(refreshToken: string) {
      this.revokeCalls++;
      order.push('apple_revoke');
      assert(refreshToken.startsWith('rt-'));
      return this.revokeResult;
    },
  };
  const authAdmin = {
    calls: 0,
    error: null as null | { status?: number; code?: string; message?: string },
    throws: false,
    async deleteUser(uid: string) {
      this.calls++;
      order.push('auth_delete');
      assertEquals(uid, UID);
      if (this.throws) throw new Error(LEAK);
      return { error: this.error };
    },
  };
  const user = { current: { id: UID } as { id: string } | null, throws: false };
  const logs: unknown[] = [];
  const ports: AdapterPorts = {
    rpc: { rpc: async (fn, args) => {
      if (fn === 'account_deletion_purge') order.push('sql_purge');
      return await backend.rpc(fn, args);
    } },
    identity: { getUser: async (_t: string) => {
      if (user.throws) throw new Error(LEAK);
      return user.current;
    } },
    apple: apple as unknown as AppleGateway,
    sealer: { seal: async (p: string) => `sealed(${p})`, unseal: async (c: string) => c.replace(/^sealed\(|\)$/g, '') },
    storage,
    authAdmin,
    config: {
      intent_verification: true, apple_signing: true, token_encryption: true,
      database: true, storage_admin: true, auth_admin: true,
    },
    ...over,
  };
  // storage sweep observability
  const origFrom = storage.from.bind(storage);
  storage.from = (b: string) => {
    const bucket = origFrom(b);
    return {
      list: bucket.list,
      remove: (paths: string[]) => {
        order.push('storage_remove');
        return bucket.remove(paths);
      },
    };
  };
  const coordinator = buildAccountDeletionCoordinator(ports, {
    log: (e) => logs.push(e),
    options: { retryBaseMs: 1, retryMaxMs: 10 },
  });
  return { backend, storage, apple, authAdmin, user, ports, coordinator, order, logs };
}

const request = (secret = SECRET, challenge = CHALLENGE) => ({
  bearerToken: 'jwt',
  challengeId: challenge,
  challengeResponse: 'apple-proof',
  receiptSecret: secret,
});

async function acceptAndRun(h: Harness) {
  const r = await h.coordinator.requestDeletion(request());
  assertEquals(r.status, 'accepted');
  if (r.status !== 'accepted') throw new Error('unreachable');
  return { r, run: await h.coordinator.processJob(r.jobId, 'w1') };
}

// ── readiness ────────────────────────────────────────────────────────────────

Deno.test('readiness lists exactly the missing configuration keys and blocks every side effect', async () => {
  const h = harness({
    config: { intent_verification: true, apple_signing: false, token_encryption: true, database: true, storage_admin: true, auth_admin: false },
  });
  const r = await h.coordinator.requestDeletion(request());
  assertEquals(r, { status: 'error', code: 'not_configured', retryable: false });
  assertEquals(h.backend.calls.length, 0);
  assertEquals(h.apple.authorizeCalls, 0);
  const adapter = createAccountDeletionAdapter(h.ports);
  assertEquals(adapter.readiness(), { ok: false, missing: ['apple_signing', 'auth_admin'] });
});

// ── success ──────────────────────────────────────────────────────────────────

Deno.test('success: Apple revoke, Storage, SQL, Auth, terminal Storage run in that order and completion is server-confirmed', async () => {
  const h = harness();
  const { run } = await acceptAndRun(h);
  assertEquals(run, { outcome: 'completed' });
  assertEquals(h.order, ['apple_revoke', 'storage_remove', 'sql_purge', 'auth_delete']);
  assertEquals(h.storage.objects.size, 0);
  const status = await h.coordinator.getStatus(SECRET);
  assertEquals(status.status, 'completed');
  // The Apple material was destroyed by completeStep(apple_revoke), never left behind.
  assertEquals([...h.backend.materials.values()].every((m) => m.state !== 'reserved' && m.cipher === ''), true);
});

Deno.test('the sealed Apple token is the only thing stored; the plaintext token never reaches an RPC', async () => {
  const h = harness();
  await acceptAndRun(h);
  const json = JSON.stringify(h.backend.calls);
  assertFalse(json.includes('"rt-1"'));
  assertStringIncludes(json, 'sealed(rt-1)');
  assertFalse(json.includes('apple-proof'));
});

// ── status before completion ─────────────────────────────────────────────────

Deno.test('status is accepted/pending, never completed, until the server records completion', async () => {
  const h = harness();
  const r = await h.coordinator.requestDeletion(request());
  assertEquals(r.status, 'accepted');
  assertEquals((await h.coordinator.getStatus(SECRET)).status, 'accepted');
  h.apple.revokeResult = 'retryable';
  if (r.status === 'accepted') await h.coordinator.processJob(r.jobId, 'w1');
  assertEquals((await h.coordinator.getStatus(SECRET)).status, 'pending');
});

// ── each step failing ────────────────────────────────────────────────────────

type StepCase = {
  name: string;
  arrange: (h: Harness) => void;
  stage: string;
  code: string;
  outcome: 'retry_scheduled' | 'failed';
  notCalled: Array<string>;
};

const stepCases: StepCase[] = [
  { name: 'Apple revoke retryable', arrange: (h) => { h.apple.revokeResult = 'retryable'; }, stage: 'apple_revoke', code: 'apple_revoke_retryable', outcome: 'retry_scheduled', notCalled: ['storage_remove', 'sql_purge', 'auth_delete'] },
  { name: 'Apple revoke rejected', arrange: (h) => { h.apple.revokeResult = 'failed'; }, stage: 'apple_revoke', code: 'apple_revoke_rejected', outcome: 'failed', notCalled: ['storage_remove', 'sql_purge', 'auth_delete'] },
  { name: 'Storage list error', arrange: (h) => { h.storage.failList = true; }, stage: 'storage_sweep', code: 'storage_error', outcome: 'retry_scheduled', notCalled: ['sql_purge', 'auth_delete'] },
  { name: 'Storage remove error', arrange: (h) => { h.storage.failRemove = true; }, stage: 'storage_sweep', code: 'storage_error', outcome: 'retry_scheduled', notCalled: ['sql_purge', 'auth_delete'] },
  { name: 'SQL purge RPC error', arrange: (h) => { h.backend.errorOn.set('account_deletion_purge', '55P03'); }, stage: 'sql_purge', code: 'sql_purge_error', outcome: 'retry_scheduled', notCalled: ['auth_delete'] },
  { name: 'Auth delete 5xx', arrange: (h) => { h.authAdmin.error = { status: 503, message: LEAK }; }, stage: 'auth_delete', code: 'auth_delete_error', outcome: 'retry_scheduled', notCalled: [] },
  { name: 'Auth delete thrown', arrange: (h) => { h.authAdmin.throws = true; }, stage: 'auth_delete', code: 'auth_delete_error', outcome: 'retry_scheduled', notCalled: [] },
  { name: 'Auth delete rejected 403', arrange: (h) => { h.authAdmin.error = { status: 403, message: LEAK }; }, stage: 'auth_delete', code: 'auth_delete_error', outcome: 'failed', notCalled: [] },
  { name: 'Auth delete bare 404 is ambiguous', arrange: (h) => { h.authAdmin.error = { status: 404, message: 'Not Found' }; }, stage: 'auth_delete', code: 'auth_delete_ambiguous', outcome: 'retry_scheduled', notCalled: [] },
];

for (const c of stepCases) {
  Deno.test(`step failure: ${c.name} records the stage, stops the saga and leaks no provider text`, async () => {
    const h = harness();
    c.arrange(h);
    const { run } = await acceptAndRun(h);
    assertEquals<unknown>(run, { outcome: c.outcome, stage: c.stage, code: c.code });
    for (const skipped of c.notCalled) assertFalse(h.order.includes(skipped), `${skipped} must not run`);
    assertFalse(JSON.stringify(h.logs).includes(LEAK));
    assertFalse(JSON.stringify(await h.coordinator.getStatus(SECRET)).includes(LEAK));
    assertEquals((await h.coordinator.getStatus(SECRET)).status, 'pending');
  });
}

Deno.test('Auth user_not_found 404 is confirmed absence and lets the saga finish', async () => {
  const h = harness();
  h.authAdmin.error = { status: 404, code: 'user_not_found', message: 'User not found' };
  const { run } = await acceptAndRun(h);
  assertEquals(run, { outcome: 'completed' });
});

Deno.test('terminal Storage incompleteness is retryable and keeps the receipt non-completed', async () => {
  let sweeps = 0;
  const h2 = harness({
    eraseObjects: async () => {
      sweeps++;
      return sweeps === 1
        ? { removed: [], complete: true, retryable: false }
        : { removed: [], complete: false, retryable: true, error: 'work_limit_reached: processed at most 1000 paths' };
    },
  });
  const { run } = await acceptAndRun(h2);
  assertEquals(run, { outcome: 'retry_scheduled', stage: 'terminal_storage', code: 'terminal_storage_incomplete' });
  assertEquals((await h2.coordinator.getStatus(SECRET)).status, 'pending');
});

// ── retries resume, not restart ──────────────────────────────────────────────

Deno.test('a retry after a mid-saga failure resumes at the failed stage and never revokes Apple twice', async () => {
  const h = harness();
  h.storage.failList = true;
  const { run } = await acceptAndRun(h);
  assertEquals(run.outcome, 'retry_scheduled');
  assertEquals(h.apple.revokeCalls, 1);
  h.storage.failList = false;
  const second = await h.coordinator.processNext('w2');
  assertEquals(second, { outcome: 'completed' });
  assertEquals(h.apple.revokeCalls, 1);
  assertEquals((await h.coordinator.getStatus(SECRET)).status, 'completed');
});

// ── SQL erasure authority ────────────────────────────────────────────────────

Deno.test('the SQL erasure entry is called with job and lease credentials, never with a bare uid or a flag', async () => {
  const h = harness();
  await acceptAndRun(h);
  const purge = h.backend.calls.find((c) => c.fn === 'account_deletion_purge')!;
  assertEquals(Object.keys(purge.args).sort(), ['p_generation', 'p_job_id', 'p_lease_token']);
  assertFalse(JSON.stringify(purge.args).includes(UID));
});

Deno.test('purge refuses a uid that does not belong to the leased job', async () => {
  const h = harness();
  const adapter = createAccountDeletionAdapter(h.ports);
  const r = await h.coordinator.requestDeletion(request());
  assertEquals(r.status, 'accepted');
  assertEquals(await adapter.steps.purgeSql(OTHER_UID), { status: 'failed' });
  assertEquals(h.order.includes('sql_purge'), false);
});

// ── lease loss ───────────────────────────────────────────────────────────────

Deno.test('a lost lease stops before any external call', async () => {
  const h = harness();
  const r = await h.coordinator.requestDeletion(request());
  assertEquals(r.status, 'accepted');
  const job = [...h.backend.jobs.values()][0];
  const orig = h.backend.rpc.bind(h.backend);
  h.backend.rpc = async (fn, args) => {
    if (fn === 'account_deletion_claim_lease') {
      const out = await orig(fn, args);
      job.leaseExpired = true; // lease replaced right after the grant
      return out;
    }
    return await orig(fn, args);
  };
  const run = await h.coordinator.processNext('w1');
  assertEquals(run, { outcome: 'lease_lost' });
  assertEquals(h.apple.revokeCalls, 0);
  assertEquals(h.order, []);
});

// ── acceptance: duplicate / conflict / already pending / expired ─────────────

Deno.test('a duplicate request returns the same job without a second Apple exchange', async () => {
  const h = harness();
  const a = await h.coordinator.requestDeletion(request());
  const b = await h.coordinator.requestDeletion(request());
  assertEquals(a.status, 'accepted');
  assertEquals(b, { status: 'accepted', duplicate: true, jobId: a.status === 'accepted' ? a.jobId : '' });
  assertEquals(h.apple.authorizeCalls, 1);
  assertEquals([...h.backend.jobs.values()].length, 1);
});

Deno.test('the same challenge with a different receipt secret is an idempotency conflict', async () => {
  const h = harness();
  await h.coordinator.requestDeletion(request());
  const b = await h.coordinator.requestDeletion(request(SECRET_2));
  assertEquals(b, { status: 'error', code: 'idempotency_conflict', retryable: false });
});

Deno.test('a fresh challenge while a job is pending attaches to it and requests disposal of the new material', async () => {
  const h = harness();
  const a = await h.coordinator.requestDeletion(request());
  const b = await h.coordinator.requestDeletion(request(SECRET_2, CHALLENGE_2));
  assertEquals(b.status, 'accepted');
  if (a.status === 'accepted' && b.status === 'accepted') {
    assertEquals(b.jobId, a.jobId);
    assertEquals(b.duplicate, true);
  }
  assertEquals([...h.backend.jobs.values()].length, 1);
  assertEquals(h.backend.names().filter((n) => n === 'account_deletion_dispose_material').length, 1);
  // the winning job's material is untouched
  assertEquals([...h.backend.materials.values()].filter((m) => m.state === 'committed').length, 1);
  // the second receipt now resolves to the same job
  assertEquals((await h.coordinator.getStatus(SECRET_2)).status, 'accepted');
});

Deno.test('an expired challenge is refused and its material is disposed', async () => {
  const h = harness();
  h.backend.tombstones.add('force');
  const orig = h.backend.rpc.bind(h.backend);
  h.backend.rpc = async (fn, args) => {
    if (fn === 'account_deletion_accept') return { data: { outcome: 'challenge_expired' }, error: null };
    return await orig(fn, args);
  };
  const r = await h.coordinator.requestDeletion(request());
  assertEquals(r, { status: 'error', code: 'challenge_expired', retryable: false });
  assertEquals(h.backend.names().includes('account_deletion_dispose_material'), true);
});

// ── identity ────────────────────────────────────────────────────────────────

Deno.test('a stale or invalid JWT is unauthenticated and touches nothing', async () => {
  const h = harness();
  h.user.current = null;
  const r = await h.coordinator.requestDeletion(request());
  assertEquals(r, { status: 'error', code: 'unauthenticated', retryable: false });
  assertEquals(h.backend.calls.length, 0);
  assertEquals(h.apple.authorizeCalls, 0);
});

Deno.test('an identity lookup outage is retryable and not an authentication verdict', async () => {
  const h = harness();
  h.user.throws = true;
  const r = await h.coordinator.requestDeletion(request());
  assertEquals(r, { status: 'error', code: 'authorization_unavailable', retryable: true });
  assertFalse(JSON.stringify(r).includes(LEAK));
});

Deno.test('Apple verdicts map to the coordinator error codes and material is not stored on refusal', async () => {
  for (const code of ['challenge_invalid', 'challenge_expired', 'challenge_replayed', 'apple_subject_mismatch', 'not_configured']) {
    const h = harness();
    h.apple.authorizeResult = { status: code };
    const r = await h.coordinator.requestDeletion(request());
    assertEquals(r.status, 'error');
    if (r.status === 'error') assertEquals(r.code, code);
    assertEquals(h.backend.names().includes('account_deletion_accept'), false);
    assertEquals(h.backend.materials.size, 0);
  }
});

Deno.test('a failure to reserve the sealed material is a retryable authorization failure before acceptance', async () => {
  const h = harness();
  h.backend.throwOn.add('account_deletion_reserve_material');
  const r = await h.coordinator.requestDeletion(request());
  assertEquals(r, { status: 'error', code: 'authorization_unavailable', retryable: true });
  assertEquals(h.backend.names().includes('account_deletion_accept'), false);
});

// ── unknown acceptance: the heart of the custody contract ───────────────────

Deno.test('unknown acceptance (accept AND fence both unreachable) retains material and cannot be read as nonacceptance', async () => {
  const h = harness();
  h.backend.throwOn.add('account_deletion_accept');
  h.backend.throwOn.add('account_deletion_fence_attempt');
  const r = await h.coordinator.requestDeletion(request());
  assertEquals(r, { status: 'error', code: 'acceptance_unknown', retryable: true, recovery: 'lookup_receipt' });
  assertEquals(h.backend.names().includes('account_deletion_dispose_material'), false);
  assertEquals([...h.backend.materials.values()][0].state, 'reserved');
  // Even if the database is reachable again, a findAccepted that would return
  // null must not be consulted as nonacceptance for the unfenced attempt.
  h.backend.throwOn.clear();
  const calls = h.backend.calls.length;
  const again = await h.coordinator.requestDeletion(request());
  assertEquals(again.status, 'error');
  if (again.status === 'error') assertEquals(again.code, 'store_unavailable');
  // the retry made no accept call: the unfenced scope is not trusted
  assertEquals(h.backend.calls.slice(calls).some((c) => c.fn === 'account_deletion_accept'), false);
  assertEquals(h.backend.names().includes('account_deletion_dispose_material'), false);
});

Deno.test('accept fails but the fence proves it can no longer commit: nonacceptance, disposal requested', async () => {
  const h = harness();
  h.backend.throwOn.add('account_deletion_accept');
  const r = await h.coordinator.requestDeletion(request());
  assertEquals(r, { status: 'error', code: 'store_unavailable', retryable: true });
  assertEquals(h.backend.names().filter((n) => n === 'account_deletion_fence_attempt').length, 1);
  assertEquals(h.backend.names().includes('account_deletion_dispose_material'), true);
  assertEquals(h.backend.jobs.size, 0);
  // the fenced attempt id cannot be replayed to commit later
  assertEquals(h.backend.tombstones.size, 1);
});

Deno.test('accept committed but its response was lost: the fence reveals the job, no disposal', async () => {
  const h = harness();
  h.backend.lostResponse.add('account_deletion_accept');
  const r = await h.coordinator.requestDeletion(request());
  assertEquals(r.status, 'accepted');
  if (r.status === 'accepted') assertEquals(r.duplicate, false);
  assertEquals(h.backend.names().includes('account_deletion_dispose_material'), false);
  assertEquals(h.backend.jobs.size, 1);
  assertEquals([...h.backend.materials.values()][0].state, 'committed');
});

Deno.test('a malformed accept answer is fenced exactly like a failure', async () => {
  const h = harness();
  const orig = h.backend.rpc.bind(h.backend);
  h.backend.rpc = async (fn, args) => {
    if (fn === 'account_deletion_accept') return { data: { outcome: 'surprise' }, error: null };
    return await orig(fn, args);
  };
  const r = await h.coordinator.requestDeletion(request());
  assertEquals(r.status, 'error');
  assertEquals(h.backend.names().includes('account_deletion_fence_attempt'), true);
});

Deno.test('findAccepted failing is reported as unknown by the coordinator, never as an empty result', async () => {
  const h = harness();
  h.backend.throwOn.add('account_deletion_find_accepted');
  const r = await h.coordinator.requestDeletion(request());
  assertEquals(r, { status: 'error', code: 'store_unavailable', retryable: true });
  assertEquals(h.apple.authorizeCalls, 0);
});

Deno.test('receipt lookup outage is unavailable, not unknown or completed', async () => {
  const h = harness();
  h.backend.throwOn.add('account_deletion_get_receipt');
  assertEquals(await h.coordinator.getStatus(SECRET), { status: 'unavailable' });
});

Deno.test('RPC error text and codes never reach the coordinator result or log', async () => {
  const h = harness();
  h.backend.errorOn.set('account_deletion_find_accepted', '55P03');
  const r = await h.coordinator.requestDeletion(request());
  assertFalse(JSON.stringify(r).includes(LEAK));
  assertFalse(JSON.stringify(h.logs).includes(LEAK));
});

// ── disposal contract ───────────────────────────────────────────────────────

Deno.test('disposeIfUnreferenced forwards only the reference and validates the structured answer', async () => {
  const h = harness();
  const adapter = createAccountDeletionAdapter(h.ports);
  h.backend.materials.set('enc:abcdefgh', { state: 'committed', cipher: 'x' });
  assertEquals(await adapter.authorizer.disposeIfUnreferenced('enc:abcdefgh'), { status: 'kept_referenced' });
  const call = h.backend.calls.at(-1)!;
  assertEquals(call.args, { p_ref: 'enc:abcdefgh' });
  h.backend.throwOn.add('account_deletion_dispose_material');
  let threw = false;
  try {
    await adapter.authorizer.disposeIfUnreferenced('enc:abcdefgh');
  } catch {
    threw = true;
  }
  assert(threw, 'a transport failure must surface so the coordinator records kept_unconfirmed');
});

// ── real Storage sweep wiring ───────────────────────────────────────────────

Deno.test('the default Storage sweep uses the ownership-checked eraseBackupObjects over the real bucket API shape', async () => {
  const h = harness();
  h.storage.objects.add(`${OTHER_UID}/theirs.bin`);
  const { run } = await acceptAndRun(h);
  assertEquals(run, { outcome: 'completed' });
  assert(h.storage.objects.has(`${OTHER_UID}/theirs.bin`), 'another account prefix must be untouched');
  assert(h.storage.listCalls >= 4, 'pre-SQL and terminal sweeps each need two empty scans');
});

// ── E6 invocation isolation: explicit deferred schedules, no timing sleeps ──

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((r) => { resolve = r; });
  return { promise, resolve };
}

function workerHarness() {
  let id = 0;
  return harness({
    randomId: () => `private-${++id}`,
    eraseObjects: async () => ({ removed: [], complete: true, retryable: false }),
    authAdmin: { deleteUser: async () => ({ error: null }) },
  });
}

function seedSqlJob(h: Harness, jobId: string, uid: string) {
  h.backend.jobs.set(jobId, {
    jobId, uid, attemptId: `attempt-${jobId}`, steps: [...DELETION_STAGES.slice(0, 2)],
    ref: null, attempts: 0, state: 'accepted', token: null, generation: 0,
    leaseExpired: false, retainedUntilMs: null, receipts: new Set(),
  });
}

// Capture a SUCCESSFUL begin response before pausing its delivery. Replacement
// may therefore happen after validation, before the coordinator dispatches purge.
function pauseSqlBegins(h: Harness) {
  const arrivals = [deferred<Record<string, unknown>>(), deferred<Record<string, unknown>>()];
  const releases = [deferred<void>(), deferred<void>()];
  const original = h.backend.rpc.bind(h.backend);
  let begins = 0;
  h.backend.rpc = async (fn, args) => {
    const result = await original(fn, args);
    if (fn === 'account_deletion_begin_step' && args.p_stage === 'sql_purge') {
      const index = begins++;
      assertEquals(result, { data: { ok: true }, error: null });
      assert(index < 2, 'only two paused workers expected');
      arrivals[index].resolve({ ...args });
      await releases[index].promise;
    }
    return result;
  };
  return { arrivals, releases };
}

for (const mixed of [false, true]) {
  Deno.test(`E6 overlapping builder ${mixed ? 'processJob/processNext' : 'processJob/processJob'} purges each UID with its own lease`, async () => {
    const h = workerHarness();
    seedSqlJob(h, 'job-a', UID);
    seedSqlJob(h, 'job-b', OTHER_UID);
    const gates = pauseSqlBegins(h);
    const old = h.coordinator.processJob('job-a', 'cached-label');
    const first = await gates.arrivals[0].promise;
    // Queue order deliberately selects the other job for processNext.
    const a = h.backend.jobs.get('job-a')!;
    h.backend.jobs.delete('job-a');
    h.backend.jobs.set('job-a', a);
    const next = mixed ? h.coordinator.processNext('cached-label') : h.coordinator.processJob('job-b', 'cached-label');
    const second = await gates.arrivals[1].promise;
    gates.releases[0].resolve();
    gates.releases[1].resolve();
    const results = await Promise.all([old, next]);
    assertEquals(results, [{ outcome: 'completed' }, { outcome: 'completed' }]);
    const purges = h.backend.calls.filter((c) => c.fn === 'account_deletion_purge').map((c) => c.args);
    assertEquals(purges, [first, second].map((a) => ({
      p_job_id: a.p_job_id, p_lease_token: a.p_lease_token, p_generation: a.p_generation,
    })));
    const workers = h.backend.calls.filter((c) => c.fn === 'account_deletion_claim_lease').map((c) => c.args.p_worker_id);
    assertEquals(new Set(workers).size, 2);
    assertFalse(workers.includes('cached-label'));
  });
}

Deno.test('E6 delayed OLD successful begin cannot borrow replacement generation for purge or completion', async () => {
  const h = workerHarness();
  seedSqlJob(h, 'job-a', UID);
  const gates = pauseSqlBegins(h);
  const old = h.coordinator.processJob('job-a', 'cached-label');
  const oldBegin = await gates.arrivals[0].promise;
  const replacement = h.coordinator.processJob('job-a', 'cached-label');
  const newBegin = await gates.arrivals[1].promise;
  assertEquals([oldBegin.p_generation, newBegin.p_generation], [1, 2]);
  gates.releases[0].resolve();
  const oldResult = await old;
  const beforeReplacement = h.backend.calls.filter((c) => c.fn === 'account_deletion_purge').map((c) => c.args);
  const oldCompletion = h.backend.calls.filter((c) => c.fn === 'account_deletion_complete_job');
  gates.releases[1].resolve();
  const newResult = await replacement;
  assertEquals(oldResult, { outcome: 'lease_lost' });
  assertEquals(beforeReplacement, [{ p_job_id: 'job-a', p_lease_token: oldBegin.p_lease_token, p_generation: 1 }]);
  assertEquals(oldCompletion, []);
  assertEquals(newResult, { outcome: 'completed' });
  assertEquals(h.backend.calls.filter((c) => c.fn === 'account_deletion_complete_job').map((c) => c.args.p_generation), [2]);
});

Deno.test('E6 raw adapter consumes its claim synchronously before the first RPC awaits', async () => {
  const h = workerHarness();
  seedSqlJob(h, 'job-a', UID);
  const arrived = deferred<void>();
  const release = deferred<void>();
  const original = h.backend.rpc.bind(h.backend);
  let calls = 0;
  h.backend.rpc = async (fn, args) => {
    const result = await original(fn, args);
    if (fn === 'account_deletion_claim_lease' && ++calls === 1) {
      arrived.resolve();
      await release.promise;
    }
    return result;
  };
  const adapter = createAccountDeletionAdapter(h.ports);
  const first = adapter.store.claimLease({ workerId: 'one', leaseMs: 1000, jobId: 'job-a' });
  await arrived.promise;
  let rejected = false;
  try {
    await adapter.store.claimLease({ workerId: 'two', leaseMs: 1000, jobId: 'job-a' });
  } catch {
    rejected = true;
  } finally {
    release.resolve();
    await first;
  }
  assert(rejected, 'concurrent reuse must reject before RPC');
  assertEquals(calls, 1);
  assertEquals(await adapter.steps.purgeSql(UID), { status: 'done' });
  assertEquals(h.backend.calls.at(-1)!.args, { p_job_id: 'job-a', p_lease_token: 'tok-1', p_generation: 1 });
});

for (const response of ['null', 'malformed', 'transport'] as const) {
  Deno.test(`E6 raw ${response} claim consumes the only attempt even without a grant`, async () => {
    const h = workerHarness();
    let calls = 0;
    h.backend.rpc = async () => {
      calls++;
      if (response === 'transport') throw new Error('offline');
      return { data: response === 'null' ? null : { unexpected: true }, error: null };
    };
    const adapter = createAccountDeletionAdapter(h.ports);
    await Promise.allSettled([adapter.store.claimLease({ workerId: 'one', leaseMs: 1000 })]);
    await assertRejects(() => adapter.store.claimLease({ workerId: 'two', leaseMs: 1000 }));
    assertEquals(calls, 1);
    assertEquals(await adapter.steps.purgeSql(UID), { status: 'failed' });
  });
}

Deno.test('E6 returned lease and job mutation cannot alter the private purge binding; rejected reuse keeps first grant', async () => {
  const h = workerHarness();
  seedSqlJob(h, 'job-a', UID);
  seedSqlJob(h, 'job-b', OTHER_UID);
  const adapter = createAccountDeletionAdapter(h.ports);
  const grant = await adapter.store.claimLease({ workerId: 'one', leaseMs: 1000, jobId: 'job-a' });
  assert(grant);
  grant.lease.jobId = 'job-b';
  grant.lease.token = 'attacker-token';
  grant.lease.generation = 999;
  grant.job.uid = OTHER_UID;
  assertEquals(await adapter.steps.purgeSql(UID), { status: 'done' });
  await assertRejects(() => adapter.store.claimLease({ workerId: 'two', leaseMs: 1000, jobId: 'job-b' }));
  assertEquals(await adapter.steps.purgeSql(OTHER_UID), { status: 'failed' });
  assertEquals(await adapter.steps.purgeSql(UID), { status: 'done' });
  assertEquals(h.backend.calls.at(-1)!.args, { p_job_id: 'job-a', p_lease_token: 'tok-1', p_generation: 1 });
  assertEquals(h.backend.names().filter((n) => n === 'account_deletion_claim_lease').length, 1);
});

Deno.test('E6 sequential builder retry gets a fresh adapter and worker ID with options and logging retained', async () => {
  const h = workerHarness();
  seedSqlJob(h, 'job-a', UID);
  h.backend.throwOn.add('account_deletion_purge');
  assertEquals((await h.coordinator.processJob('job-a', 'same-label')).outcome, 'retry_scheduled');
  h.backend.throwOn.clear();
  assertEquals(await h.coordinator.processNext('same-label'), { outcome: 'completed' });
  const claims = h.backend.calls.filter((c) => c.fn === 'account_deletion_claim_lease');
  assertEquals(new Set(claims.map((c) => c.args.p_worker_id)).size, 2);
  const failure = h.backend.calls.find((c) => c.fn === 'account_deletion_record_failure')!;
  assertEquals(failure.args.p_retry_delay_ms, 1);
  assert(h.logs.some((e) => (e as { event?: string }).event === 'completed'));
});

Deno.test('E6 builder snapshots configuration and coordinator options consistently', async () => {
  const h = workerHarness();
  seedSqlJob(h, 'job-a', UID);
  const options = { leaseMs: 12345, receiptRetentionMs: 7_200_000, retryBaseMs: 1, retryMaxMs: 10 };
  const coordinator = buildAccountDeletionCoordinator(h.ports, { options });
  h.ports.config.database = false;
  options.leaseMs = 9999;
  options.receiptRetentionMs = 9_000_000;
  assertEquals(await coordinator.processJob('job-a', 'label'), { outcome: 'completed' });
  assertEquals(h.backend.calls.find((c) => c.fn === 'account_deletion_claim_lease')!.args.p_lease_ms, 12345);
  assertEquals(h.backend.calls.find((c) => c.fn === 'account_deletion_complete_job')!.args.p_receipt_retention_ms, 7_200_000);
  // The request/status coordinator sees the same original config snapshot.
  assertEquals((await coordinator.requestDeletion(request())).status, 'accepted');
});

Deno.test('E6 one cached handler plus builder isolates concurrent real request workers and receipt-only status', async () => {
  let id = 0;
  const h = harness({
    randomId: () => `handler-private-${++id}`,
    identity: { getUser: async (token) => ({ id: token === 'jwt-a' ? UID : OTHER_UID }) },
    apple: {
      authorize: async () => ({ status: 'ok', refreshToken: 'rt-handler', challengeExpiresAtMs: 9_999_999 }),
      revoke: async () => 'revoked_verified',
    },
    authAdmin: { deleteUser: async () => ({ error: null }) },
    eraseObjects: async () => ({ removed: [], complete: true, retryable: false }),
  });
  const handler = createDeleteAccountHandler({ coordinator: h.coordinator, workerId: 'cached-handler' });
  const post = (token: string, secret: string, action = 'request') => new Request('https://offline.invalid/delete', {
    method: 'POST', headers: { authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(action === 'status'
      ? { action: 'status', receipt_secret: secret }
      : { action, challenge_id: CHALLENGE, challenge_response: 'apple-proof', receipt_secret: secret }),
  });
  const gates = pauseSqlBegins(h);
  const first = handler(post('jwt-a', SECRET));
  await gates.arrivals[0].promise;
  const second = handler(post('jwt-b', SECRET_2));
  await gates.arrivals[1].promise;
  // Receipt exists, but no terminal completion has been recorded.
  const before = h.backend.calls.length;
  const pending = await handler(post('jwt-a', SECRET, 'status'));
  assertEquals(await pending.json(), { status: 'in_progress' });
  assertEquals(h.backend.calls.slice(before).map((c) => c.fn), ['account_deletion_get_receipt']);
  gates.releases[0].resolve();
  gates.releases[1].resolve();
  const results = await Promise.all([first, second]);
  assertEquals(results.map((r) => r.status), [200, 200]);
  assertEquals(await Promise.all(results.map((r) => r.json())), [{ status: 'completed' }, { status: 'completed' }]);
  const claims = h.backend.calls.filter((c) => c.fn === 'account_deletion_claim_lease');
  assertEquals(new Set(claims.map((c) => c.args.p_worker_id)).size, 2);
  assertFalse(claims.some((c) => c.args.p_worker_id === 'cached-handler'));
  assertEquals(h.backend.calls.filter((c) => c.fn === 'account_deletion_purge').map((c) => c.args), claims.map((c) => ({
    p_job_id: c.args.p_job_id, p_lease_token: 'tok-1', p_generation: 1,
  })));
  for (const secret of [SECRET, SECRET_2]) {
    assertEquals(await (await handler(post('jwt-a', secret, 'status'))).json(), { status: 'completed' });
  }
});
