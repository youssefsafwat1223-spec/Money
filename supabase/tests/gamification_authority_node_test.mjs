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
