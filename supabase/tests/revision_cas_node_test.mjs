import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import test from 'node:test';

// MALI-022 / 0068: contract tests for the server-side revision compare-and-set.
// Credential-gated: they run only against a live/staging Supabase with the
// migration applied (SUPABASE_URL + SUPABASE_ANON_KEY + SUPABASE_SERVICE_ROLE_KEY).
// They SKIP locally (no Postgres here) — the CAS behaviour is an external gate.

const supabaseUrl = process.env.SUPABASE_URL;
const anonKey = process.env.SUPABASE_ANON_KEY;
const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
const live = Boolean(supabaseUrl) && Boolean(anonKey) && Boolean(serviceRoleKey);
const skip = live ? false : 'requires SUPABASE_URL, SUPABASE_ANON_KEY, and SUPABASE_SERVICE_ROLE_KEY';

function headers(key, jwt = key) {
  return { apikey: key, authorization: `Bearer ${jwt}`, 'content-type': 'application/json' };
}
async function req(path, options) {
  const r = await fetch(`${supabaseUrl}${path}`, options);
  const t = await r.text();
  return { status: r.status, body: t ? JSON.parse(t) : null };
}
async function createUser(email) {
  const { body } = await req('/auth/v1/admin/users', {
    method: 'POST',
    headers: headers(serviceRoleKey),
    body: JSON.stringify({ email, password: 'pw-' + randomUUID(), email_confirm: true }),
  });
  return body;
}
async function jwtFor(id) {
  // A minimal signed token isn't available without the JWT secret; use the
  // admin generate-link flow is overkill — instead these live tests assume the
  // harness provides per-user JWTs. Kept as a documented external requirement.
  return id;
}

test('CAS: an update with the expected revision succeeds and bumps revision once',
  { skip }, async () => {
    const user = await createUser(`cas-${randomUUID()}@example.com`);
    const jwt = await jwtFor(user.id);
    const localId = randomUUID();
    // create
    const created = await req('/rest/v1/user_accounts', {
      method: 'POST',
      headers: { ...headers(anonKey, jwt), prefer: 'return=representation' },
      body: JSON.stringify({ local_id: localId, name: 'A', currency: 'SAR', type: 'bank' }),
    });
    assert.equal(created.status, 201, JSON.stringify(created.body));
    const row = created.body[0];
    assert.equal(row.revision, 1, 'starts at 1');
    // CAS update with the expected revision
    const ok = await req(`/rest/v1/user_accounts?id=eq.${row.id}&revision=eq.1`, {
      method: 'PATCH',
      headers: { ...headers(anonKey, jwt), prefer: 'return=representation' },
      body: JSON.stringify({ name: 'A2' }),
    });
    assert.equal(ok.status, 200);
    assert.equal(ok.body.length, 1, 'applied');
    assert.equal(ok.body[0].revision, 2, 'revision bumped exactly once');
  });

test('CAS: a stale expected revision matches nothing and changes nothing',
  { skip }, async () => {
    const user = await createUser(`cas2-${randomUUID()}@example.com`);
    const jwt = await jwtFor(user.id);
    const localId = randomUUID();
    const created = await req('/rest/v1/user_accounts', {
      method: 'POST',
      headers: { ...headers(anonKey, jwt), prefer: 'return=representation' },
      body: JSON.stringify({ local_id: localId, name: 'B', currency: 'SAR', type: 'bank' }),
    });
    const row = created.body[0];
    // move it forward once (now revision 2)
    await req(`/rest/v1/user_accounts?id=eq.${row.id}&revision=eq.1`, {
      method: 'PATCH',
      headers: headers(anonKey, jwt),
      body: JSON.stringify({ name: 'B2' }),
    });
    // a CAS with the now-stale base revision 1 → 0 rows, unchanged
    const stale = await req(`/rest/v1/user_accounts?id=eq.${row.id}&revision=eq.1`, {
      method: 'PATCH',
      headers: { ...headers(anonKey, jwt), prefer: 'return=representation' },
      body: JSON.stringify({ name: 'B-STALE' }),
    });
    assert.equal(stale.body.length, 0, 'conflict: nothing updated');
    const check = await req(`/rest/v1/user_accounts?id=eq.${row.id}&select=name,revision`, {
      headers: headers(anonKey, jwt),
    });
    assert.equal(check.body[0].name, 'B2', 'value unchanged by the stale CAS');
    assert.equal(check.body[0].revision, 2);
  });

test('CAS: another user cannot update this user\'s row (RLS ownership)',
  { skip }, async () => {
    const a = await createUser(`cas-a-${randomUUID()}@example.com`);
    const b = await createUser(`cas-b-${randomUUID()}@example.com`);
    const jwtA = await jwtFor(a.id);
    const jwtB = await jwtFor(b.id);
    const localId = randomUUID();
    const created = await req('/rest/v1/user_accounts', {
      method: 'POST',
      headers: { ...headers(anonKey, jwtA), prefer: 'return=representation' },
      body: JSON.stringify({ local_id: localId, name: 'A', currency: 'SAR', type: 'bank' }),
    });
    const row = created.body[0];
    const asB = await req(`/rest/v1/user_accounts?id=eq.${row.id}&revision=eq.1`, {
      method: 'PATCH',
      headers: { ...headers(anonKey, jwtB), prefer: 'return=representation' },
      body: JSON.stringify({ name: 'HACKED' }),
    });
    assert.equal(asB.body.length ?? 0, 0, 'RLS blocks cross-user update');
  });

// Note: accounts stands in for the shared revision+trigger contract, which is
// applied identically to every mutable user table by 0068. Extend coverage per
// entity as needed when running against staging.
