// MALI-024 (Batch-5 closure) — credential-gated real-Postgres proof, via the
// Supabase REST API (no SDK import, matching the other node tests), that:
//   * a normal authenticated client cannot INSERT/UPDATE its own authoritative
//     XP aggregate (RLS denies it), but may still SELECT it;
//   * the legacy award ledger dedups a replayed transaction id.
// Requires migrations 0056/0062/0072/0073 applied. Skips (reported honestly)
// when no Supabase credentials are present; the static SHAPE is proven in
// backend_hardening_contract_test.mjs.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import test from 'node:test';

const url = process.env.SUPABASE_URL;
const anon = process.env.SUPABASE_ANON_KEY;
const service = process.env.SUPABASE_SERVICE_ROLE_KEY;
const live = url && anon && service;
const gate = { skip: live ? false : 'requires SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY' };

const svcHeaders = () => ({ apikey: service, Authorization: `Bearer ${service}`, 'Content-Type': 'application/json' });

test('authenticated client cannot INSERT/UPDATE its own XP aggregate', gate, async () => {
  const email = `gami-${randomUUID()}@example.test`;
  const password = randomUUID();
  const createRes = await fetch(`${url}/auth/v1/admin/users`, {
    method: 'POST',
    headers: svcHeaders(),
    body: JSON.stringify({ email, password, email_confirm: true }),
  });
  const created = await createRes.json();
  const uid = created.id;
  assert.ok(uid, `create user failed: ${JSON.stringify(created)}`);
  try {
    const tokenRes = await fetch(`${url}/auth/v1/token?grant_type=password`, {
      method: 'POST',
      headers: { apikey: anon, 'Content-Type': 'application/json' },
      body: JSON.stringify({ email, password }),
    });
    const token = (await tokenRes.json()).access_token;
    assert.ok(token, 'sign-in failed');
    const userHeaders = { apikey: anon, Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' };

    // Forged INSERT must be denied by RLS (no owner INSERT policy after 0073).
    const ins = await fetch(`${url}/rest/v1/user_xp_levels`, {
      method: 'POST', headers: userHeaders,
      body: JSON.stringify({ user_id: uid, xp: 999999, level: 99 }),
    });
    assert.ok(ins.status >= 400, `forged INSERT must be denied, got ${ins.status}`);

    // Server seeds a row; the user's UPDATE must be denied.
    await fetch(`${url}/rest/v1/user_xp_levels`, {
      method: 'POST', headers: { ...svcHeaders(), Prefer: 'resolution=merge-duplicates' },
      body: JSON.stringify({ user_id: uid, xp: 0, level: 1 }),
    });
    const upd = await fetch(`${url}/rest/v1/user_xp_levels?user_id=eq.${uid}`, {
      method: 'PATCH', headers: userHeaders, body: JSON.stringify({ xp: 123456 }),
    });
    // PATCH with no matching writable row → 0 rows affected (403/empty), never applied.
    const seed = await (await fetch(`${url}/rest/v1/user_xp_levels?user_id=eq.${uid}&select=xp`, { headers: svcHeaders() })).json();
    assert.equal(seed[0]?.xp, 0, `forged UPDATE must not land (got ${JSON.stringify(seed)}, patch ${upd.status})`);

    // Owner SELECT stays allowed.
    const sel = await fetch(`${url}/rest/v1/user_xp_levels?user_id=eq.${uid}&select=xp`, { headers: userHeaders });
    assert.equal(sel.status, 200, 'owner SELECT must be allowed');
  } finally {
    await fetch(`${url}/auth/v1/admin/users/${uid}`, { method: 'DELETE', headers: svcHeaders() });
  }
});

test('legacy award ledger dedups a replayed transaction id', gate, async () => {
  const txnId = `test-${randomUUID()}`;
  const uid = randomUUID();
  const insert = () => fetch(`${url}/rest/v1/gamification_awarded_transactions`, {
    method: 'POST', headers: { ...svcHeaders(), Prefer: 'return=representation' },
    body: JSON.stringify({ transaction_id: txnId, user_id: uid }),
  });
  try {
    const first = await insert();
    assert.equal(first.status, 201, 'first claim succeeds');
    const second = await insert();
    assert.ok(second.status >= 400, `replayed id must conflict, got ${second.status}`);
  } finally {
    await fetch(`${url}/rest/v1/gamification_awarded_transactions?transaction_id=eq.${txnId}`, { method: 'DELETE', headers: svcHeaders() });
  }
});

// MALI-024 §4 (closure) — the atomic award RPC is crash-safe exactly-once. The
// claim and the XP mutation share ONE Postgres transaction, so these observable
// behaviours prove: no duplicate XP, no lost XP, no partial state, a lost-
// response retry reconstructs the same canonical result, and ownership is
// enforced server-side. (A mid-transaction crash cannot leave partial state —
// that is Postgres atomicity of the single function body, asserted structurally
// in backend_hardening_contract_test.mjs.)
const awardRpc = (txnId, uid) => fetch(`${url}/rest/v1/rpc/award_gamification_for_transaction`, {
  method: 'POST', headers: svcHeaders(),
  body: JSON.stringify({ p_transaction_id: txnId, p_user_id: uid }),
}).then((r) => r.json());

const seedUserWithTxn = async () => {
  const email = `gami-${randomUUID()}@example.test`;
  const password = randomUUID();
  const created = await (await fetch(`${url}/auth/v1/admin/users`, {
    method: 'POST', headers: svcHeaders(),
    body: JSON.stringify({ email, password, email_confirm: true }),
  })).json();
  const uid = created.id;
  assert.ok(uid, `create user failed: ${JSON.stringify(created)}`);
  const txn = await (await fetch(`${url}/rest/v1/user_transactions`, {
    method: 'POST', headers: { ...svcHeaders(), Prefer: 'return=representation' },
    body: JSON.stringify({
      user_id: uid, amount: 12.5, currency: 'SAR', type: 'debit',
      occurred_at: new Date().toISOString(), source: 'manual',
    }),
  })).json();
  return { uid, txnId: txn[0].id };
};

const xpOf = async (uid) => {
  const rows = await (await fetch(`${url}/rest/v1/user_xp_levels?user_id=eq.${uid}&select=xp`, { headers: svcHeaders() })).json();
  return rows[0]?.xp ?? 0;
};

const cleanup = async (uid) => {
  await fetch(`${url}/rest/v1/gamification_awarded_transactions?user_id=eq.${uid}`, { method: 'DELETE', headers: svcHeaders() });
  await fetch(`${url}/auth/v1/admin/users/${uid}`, { method: 'DELETE', headers: svcHeaders() });
};

test('award RPC: sequential replay awards XP exactly once (lost-response safe)', gate, async () => {
  const { uid, txnId } = await seedUserWithTxn();
  try {
    const first = await awardRpc(txnId, uid);
    assert.equal(first.awarded, true);
    assert.equal(first.duplicate, false, 'first call is the winner');
    const second = await awardRpc(txnId, uid);
    assert.equal(second.awarded, true);
    assert.equal(second.duplicate, true, 'replay must be a duplicate, not a re-award');
    // Canonical result is reconstructed identically.
    assert.equal(second.achievement, first.achievement);
    assert.equal(second.leveled_up, first.leveled_up);
    assert.equal(await xpOf(uid), 10, 'XP awarded exactly once across the replay');
  } finally {
    await cleanup(uid);
  }
});

test('award RPC: two concurrent workers award XP exactly once', gate, async () => {
  const { uid, txnId } = await seedUserWithTxn();
  try {
    const [a, b] = await Promise.all([awardRpc(txnId, uid), awardRpc(txnId, uid)]);
    assert.ok(a.awarded && b.awarded, 'both calls resolve to an award result');
    const winners = [a, b].filter((r) => r.duplicate === false).length;
    assert.equal(winners, 1, 'exactly one worker wins the claim');
    assert.equal(await xpOf(uid), 10, 'XP awarded exactly once under concurrency');
  } finally {
    await cleanup(uid);
  }
});

test('award RPC: rejects a transaction that does not belong to the caller user', gate, async () => {
  const owner = await seedUserWithTxn();
  const stranger = await seedUserWithTxn();
  try {
    // Try to award owner's transaction to the stranger user.
    const res = await awardRpc(owner.txnId, stranger.uid);
    assert.equal(res.awarded, false, 'non-owner award must be refused');
    assert.equal(res.reason, 'not_owner');
    assert.equal(await xpOf(stranger.uid), 0, 'no XP granted to the non-owner');
  } finally {
    await cleanup(owner.uid);
    await cleanup(stranger.uid);
  }
});
