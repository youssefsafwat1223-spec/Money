import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { handleSyncCaptures } from './index.ts';
import { captureContentLive, CAPTURE_RETENTION_MS } from '../process-ios-sms/capture_rpc_fake.ts';

// sync-captures: ownership scope, no auto-claim, tombstone ACK, v2 JWT scope.

const A = '00000000-0000-0000-0000-00000000a001';
const B = '00000000-0000-0000-0000-00000000b002';

type Row = Record<string, unknown>;

// In-memory processed_captures + the capture_sync_list / capture_ack RPCs (SQL authority:
// supabase/tests/capture_expiry_fence.sql, capture_state_machine_p1.sql). The table itself
// is NOT readable: sync-captures must go through the RPC, which applies the 7-day fence
// (F1) with the DATABASE clock (`store.dbNowMs`), never the function's own clock.
function fakeStore(rows: Row[]) {
  const log = { updates: 0, ackCalls: [] as Row[], listCalls: [] as Row[] };
  const store = { dbNowMs: Date.parse('2026-09-08T00:00:00Z') };
  const from = (table: string) => {
    if (table === 'processed_captures') throw new Error('sync-captures must not read processed_captures directly (F1)');
    return { update: () => (log.updates++, {}) };
  };
  const rpc = (fn: string, args: Row) => {
    if (fn === 'bump_capture_rate_limit') return Promise.resolve({ data: false, error: null });
    if (fn === 'capture_sync_list') {
      log.listCalls.push(args);
      const scope = rows.filter((r) =>
        r.install_id_hash === args.p_install_id_hash && (r.claimed_user_id ?? null) === args.p_user_id
      );
      for (const r of scope) {
        if (
          ['processing', 'processed', 'retryable', 'rejected'].includes(r.state as string) &&
          !captureContentLive(Date.parse(r.created_at as string), store.dbNowMs)
        ) {
          Object.assign(r, { state: 'expired', parsed: {}, notification: {}, sanitized_text: null });
        }
      }
      const states = args.p_include_state ? ['processed', 'rejected', 'retryable'] : ['processed', 'rejected'];
      const data = scope
        .filter((r) => states.includes(r.state as string))
        .sort((x, y) => String(x.created_at).localeCompare(String(y.created_at)))
        .slice(0, 50)
        .map((r) => {
          const { payload_id, status, parsed, notification, sanitized_text, failure_reason, created_at, state } = r;
          const out = { payload_id, status, parsed, notification, sanitized_text, failure_reason, created_at };
          return args.p_include_state ? { ...out, state } : out;
        });
      return Promise.resolve({ data, error: null });
    }
    log.ackCalls.push(args);
    let n = 0;
    for (const r of rows) {
      if (
        r.install_id_hash === args.p_install_id_hash &&
        (args.p_payload_ids as string[]).includes(r.payload_id as string) &&
        (r.claimed_user_id ?? null) === args.p_user_id &&
        ['processed', 'retryable', 'rejected', 'expired'].includes(r.state as string)
      ) {
        Object.assign(r, { state: 'consumed', parsed: {}, notification: {}, sanitized_text: null });
        n++;
      }
    }
    return Promise.resolve({ data: n, error: null });
  };
  return { log, store, client: { from, rpc } };
}

function row(payload: string, claimed: string | null, state = 'processed', extra: Row = {}): Row {
  return {
    install_id_hash: 'h',
    payload_id: payload,
    claimed_user_id: claimed,
    state,
    status: state === 'rejected' ? 'rejected' : 'processed',
    parsed: { amount: 10 },
    notification: { title: 't' },
    sanitized_text: null,
    failure_reason: null,
    created_at: '2026-09-07T19:30:00Z',
    ...extra,
  };
}

function call(
  rows: Row[],
  device: { userId: string | null; revoked?: boolean },
  body: Record<string, unknown>,
  jwt: { ok: true; userId: string } | { ok: false; status: number; error: string } = {
    ok: false,
    status: 401,
    error: 'missing_jwt',
  },
  dbNowMs?: number,
) {
  const store = fakeStore(rows);
  if (dbNowMs != null) store.store.dbNowMs = dbNowMs;
  const res = handleSyncCaptures(
    new Request('https://example.test/sync-captures', {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: 'Bearer x' },
      body: JSON.stringify({ installId: 'i', deviceSecret: 's', ...body }),
    }),
    {
      createServiceClient: (() => store.client) as never,
      verifyDevice: (() =>
        Promise.resolve(
          device.revoked
            ? { ok: false, status: 401, error: 'credential_revoked' }
            : { ok: true, installIdHash: 'h', userId: device.userId },
        )) as never,
      verifyUserJwt: (() => Promise.resolve(jwt)) as never,
    },
  );
  return { store, res };
}

Deno.test('T-S11 legacy: returns only rows claimed by the device user; never another user or ownerless rows; no claim UPDATE', async () => {
  const rows = [row('mine', A), row('other', B), row('ownerless', null)];
  const { store, res } = call(rows, { userId: A }, {});
  const out = await (await res).json();
  assertEquals(out.captures.map((c: Row) => c.payload_id), ['mine']);
  assertEquals(store.log.updates, 0);
  assertEquals(rows.find((r) => r.payload_id === 'ownerless')!.claimed_user_id, null);
});

Deno.test('T-S11 legacy: ownerless rows are never auto-claimed when a user links (no ownerless row is returned)', async () => {
  const rows = [row('ownerless', null)];
  const { store, res } = call(rows, { userId: A }, {});
  assertEquals((await (await res).json()).captures, []);
  assertEquals(store.log.updates, 0);
});

Deno.test('legacy guest (no linked user) sees only NULL-owner rows', async () => {
  const rows = [row('g', null), row('a', A)];
  const out = await (await call(rows, { userId: null }, {}).res).json();
  assertEquals(out.captures.map((c: Row) => c.payload_id), ['g']);
});

Deno.test('legacy: reads through capture_sync_list WITHOUT state (build-50 columns), v2 asks for state', async () => {
  const rows = [row('a', A)];
  const legacy = call(rows, { userId: A }, {});
  const out = await (await legacy.res).json();
  assertEquals(legacy.store.log.listCalls, [{ p_install_id_hash: 'h', p_user_id: A, p_include_state: false }]);
  assertEquals(Object.keys(out.captures[0]).sort(), [
    'created_at',
    'failure_reason',
    'notification',
    'parsed',
    'payload_id',
    'sanitized_text',
    'status',
  ]);
  const v2 = call(rows, { userId: A }, { schema_version: 2 }, { ok: true, userId: A });
  await v2.res;
  assertEquals(v2.store.log.listCalls[0].p_include_state, true);
  const src = await Deno.readTextFile(new URL('./index.ts', import.meta.url));
  assert(!src.includes(".from('processed_captures')"), 'no direct table read');
});

Deno.test('legacy only returns delivered states (processing/retryable/consumed/expired never leak)', async () => {
  const rows = ['processing', 'retryable', 'consumed', 'expired'].map((s) => row(s, A, s));
  rows.push(row('ok', A), row('rej', A, 'rejected'));
  const out = await (await call(rows, { userId: A }, {}).res).json();
  assertEquals(out.captures.map((c: Row) => c.payload_id).sort(), ['ok', 'rej']);
});

Deno.test('ACK is a tombstone via capture_ack (content nulled), scoped to the device user, never from processing', async () => {
  const rows = [row('p1', A), row('p2', A, 'processing'), row('x', B)];
  const { store, res } = call(rows, { userId: A }, { ackPayloadIds: ['p1', 'p2', 'x'] });
  const out = await (await res).json();
  assertEquals(store.log.ackCalls[0].p_user_id, A);
  assertEquals(rows.map((r) => r.state), ['consumed', 'processing', 'processed']);
  assertEquals(rows[0].parsed, {});
  assertEquals(out.captures.map((c: Row) => c.payload_id), []);
});

Deno.test('revoked device is refused (401 credential_revoked)', async () => {
  const r = await call([row('p', A)], { userId: A, revoked: true }, {}).res;
  assertEquals([r.status, (await r.json()).error], [401, 'credential_revoked']);
});

Deno.test('v2 requires the user JWT', async () => {
  const r = await call([row('p', A)], { userId: A }, { schema_version: 2 }).res;
  assertEquals([r.status, (await r.json()).error], [401, 'missing_jwt']);
});

Deno.test('v2: jwt.uid != device user -> 409 capture_owner_mismatch, nothing returned or consumed', async () => {
  const rows = [row('p', A)];
  const { store, res } = call(rows, { userId: A }, { schema_version: 2, ackPayloadIds: ['p'] }, {
    ok: true,
    userId: B,
  });
  const r = await res;
  assertEquals([r.status, (await r.json()).error], [409, 'capture_owner_mismatch']);
  assertEquals(store.log.ackCalls.length, 0);
  assertEquals(rows[0].state, 'processed');
});

Deno.test('v2: device with no linked user -> 409 even with a valid JWT', async () => {
  const r = await call([row('p', null)], { userId: null }, { schema_version: 2 }, { ok: true, userId: A }).res;
  assertEquals(r.status, 409);
});

Deno.test('v2: jwt.uid == device user == claimed_user_id returns state and includes retryable', async () => {
  const rows = [row('a', A), row('r', A, 'retryable'), row('b', B), row('n', null)];
  const out = await (await call(rows, { userId: A }, { schema_version: 2 }, { ok: true, userId: A }).res).json();
  assertEquals(out.captures.map((c: Row) => [c.payload_id, c.state]), [['a', 'processed'], ['r', 'retryable']]);
});

// F1: the 7-day logical expiry fence on the sync read path.
Deno.test('F1 boundaries: an expired row is never returned with content (legacy and v2); 7d-1ms still is', async () => {
  const created = Date.parse('2026-09-01T00:00:00Z');
  const createdAt = new Date(created).toISOString();
  for (
    const [name, delta, live] of [['7d-1ms', -1, true], ['exactly 7d', 0, false], ['7d+1ms', 1, false]] as const
  ) {
    for (const body of [{}, { schema_version: 2 }]) {
      const rows = [row('p', A, 'processed', { created_at: createdAt }), row('q', A, 'rejected', { created_at: createdAt })];
      const jwt = { ok: true, userId: A } as const;
      const out = await (await call(rows, { userId: A }, body, jwt, created + CAPTURE_RETENTION_MS + delta).res).json();
      if (live) {
        assertEquals(out.captures.map((c: Row) => c.payload_id), ['p', 'q'], name);
        assertEquals((out.captures[0].parsed as Row).amount, 10, name);
      } else {
        assertEquals(out.captures, [], name);
        // opportunistic null: the row is expired with no content left
        assertEquals(rows.map((r) => [r.state, r.parsed, r.notification, r.sanitized_text]), [
          ['expired', {}, {}, null],
          ['expired', {}, {}, null],
        ], name);
      }
    }
  }
  assert(captureContentLive(0, CAPTURE_RETENTION_MS - 1) && !captureContentLive(0, CAPTURE_RETENTION_MS));
});

Deno.test('F1: expired retryable rows are not returned by v2, and sync failure fails closed (no rows, 500)', async () => {
  const created = Date.parse('2026-09-01T00:00:00Z');
  const rows = [row('r', A, 'retryable', { created_at: new Date(created).toISOString() })];
  const out = await (await call(rows, { userId: A }, { schema_version: 2 }, { ok: true, userId: A }, created + CAPTURE_RETENTION_MS).res).json();
  assertEquals(out.captures, []);
  assertEquals(rows[0].state, 'expired');
  const store = fakeStore([row('p', A)]);
  store.client.rpc = ((fn: string) =>
    Promise.resolve(fn === 'bump_capture_rate_limit' ? { data: false, error: null } : { data: null, error: { message: 'x' } })) as never;
  const res = await handleSyncCaptures(
    new Request('https://example.test/sync-captures', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ installId: 'i', deviceSecret: 's' }),
    }),
    {
      createServiceClient: (() => store.client) as never,
      verifyDevice: (() => Promise.resolve({ ok: true, installIdHash: 'h', userId: A })) as never,
      verifyUserJwt: (() => Promise.resolve({ ok: false, status: 401, error: 'x' })) as never,
    },
  );
  assertEquals([res.status, (await res.json()).error], [500, 'sync_failed']);
});

Deno.test('F1: ACK of an expired row still consumes it (content stays null) and it is never returned', async () => {
  const created = Date.parse('2026-09-01T00:00:00Z');
  const rows = [row('p', A, 'processed', { created_at: new Date(created).toISOString() })];
  const { res } = call(rows, { userId: A }, { ackPayloadIds: ['p'] }, undefined, created + CAPTURE_RETENTION_MS);
  assertEquals((await (await res).json()).captures, []);
  assertEquals([rows[0].state, rows[0].parsed], ['consumed', {}]);
});
