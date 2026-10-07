import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { handleSyncCaptures } from './index.ts';

// sync-captures: ownership scope, no auto-claim, tombstone ACK, v2 JWT scope.

const A = '00000000-0000-0000-0000-00000000a001';
const B = '00000000-0000-0000-0000-00000000b002';

type Row = Record<string, unknown>;

// In-memory processed_captures + the capture_ack RPC (SQL authority:
// supabase/tests/capture_state_machine_p1.sql).
function fakeStore(rows: Row[]) {
  const log = { updates: 0, ackCalls: [] as Row[], filters: [] as Array<[string, unknown]> };
  const from = (table: string) => {
    const f: { eq: Row; isNull: string[]; inStates: string[] | null; op: string } = {
      eq: {},
      isNull: [],
      inStates: null,
      op: 'select',
    };
    const run = () => {
      if (table !== 'processed_captures') return { data: [], error: null };
      const data = rows
        .filter((r) => Object.entries(f.eq).every(([k, v]) => r[k] === v))
        .filter((r) => f.isNull.every((k) => r[k] == null))
        .filter((r) => !f.inStates || f.inStates.includes(r.state as string))
        .map((r) => ({ ...r }));
      return { data, error: null };
    };
    const b: Record<string, unknown> = {
      select: () => b,
      update: () => {
        log.updates++; // any update from sync-captures would be an auto-claim
        return b;
      },
      delete: () => {
        throw new Error('sync-captures must tombstone through capture_ack, never DELETE');
      },
      eq: (k: string, v: unknown) => {
        f.eq[k] = v;
        log.filters.push([k, v]);
        return b;
      },
      is: (k: string, _v: unknown) => {
        f.isNull.push(k);
        log.filters.push([k, null]);
        return b;
      },
      in: (k: string, v: string[]) => {
        if (k === 'state') f.inStates = v;
        return b;
      },
      order: () => b,
      limit: () => b,
      then: (resolve: (v: unknown) => unknown) => Promise.resolve(run()).then(resolve),
    };
    return b;
  };
  const rpc = (fn: string, args: Row) => {
    if (fn === 'bump_capture_rate_limit') return Promise.resolve({ data: false, error: null });
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
  return { log, client: { from, rpc } };
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
) {
  const store = fakeStore(rows);
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

Deno.test('legacy select list is exactly the build-50 columns', async () => {
  const src = await Deno.readTextFile(new URL('./index.ts', import.meta.url));
  assert(src.includes("'payload_id,status,parsed,notification,sanitized_text,failure_reason,created_at'"));
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
