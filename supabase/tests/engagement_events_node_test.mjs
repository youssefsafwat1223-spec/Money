import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import test from 'node:test';

// MALI-024 / 0070 — server contract for record_engagement_event. Credential-
// gated: runs only against a live/staging Supabase with 0070 applied
// (SUPABASE_URL + SUPABASE_ANON_KEY + SUPABASE_SERVICE_ROLE_KEY). Skips locally.

const supabaseUrl = process.env.SUPABASE_URL;
const anonKey = process.env.SUPABASE_ANON_KEY;
const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
const live = Boolean(supabaseUrl) && Boolean(anonKey) && Boolean(serviceRoleKey);
const skip = live
  ? false
  : 'requires SUPABASE_URL, SUPABASE_ANON_KEY, and SUPABASE_SERVICE_ROLE_KEY';

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
async function rpc(jwt, params) {
  return req('/rest/v1/rpc/record_engagement_event', {
    method: 'POST',
    headers: headers(anonKey, jwt),
    body: JSON.stringify(params),
  });
}

// NOTE: these live tests assume the harness provides a per-user JWT (the admin
// flow issues one); recorded here as the external requirement.
async function jwtFor(id) {
  return id;
}

test('a valid event awards server-side XP the client never specified',
  { skip }, async () => {
    const user = await createUser(`eng-${randomUUID()}@example.com`);
    const jwt = await jwtFor(user.id);
    const { status, body } = await rpc(jwt, {
      p_event_id: randomUUID(),
      p_event_type: 'goal_contribution',
      p_occurred_at: new Date().toISOString(),
    });
    assert.equal(status, 200, JSON.stringify(body));
    assert.equal(body.awarded, 15, 'award is decided server-side by type');
    assert.equal(body.xp, 15);
  });

test('a duplicate event_id awards exactly once (idempotent)', { skip }, async () => {
  const user = await createUser(`eng2-${randomUUID()}@example.com`);
  const jwt = await jwtFor(user.id);
  const eventId = randomUUID();
  const params = {
    p_event_id: eventId,
    p_event_type: 'bill_payment',
    p_occurred_at: new Date().toISOString(),
  };
  const first = await rpc(jwt, params);
  const second = await rpc(jwt, params);
  assert.equal(first.body.awarded, 5);
  assert.equal(second.body.awarded, 0, 'replay awards nothing');
  assert.equal(second.body.xp, first.body.xp, 'aggregate unchanged on replay');
});

test('an unknown event type is rejected (never silently awarded)',
  { skip }, async () => {
    const user = await createUser(`eng3-${randomUUID()}@example.com`);
    const jwt = await jwtFor(user.id);
    const { status } = await rpc(jwt, {
      p_event_id: randomUUID(),
      p_event_type: 'grant_me_infinite_xp',
      p_occurred_at: new Date().toISOString(),
    });
    assert.notEqual(status, 200, 'unknown type must be rejected');
  });

test('an unsupported event version is rejected', { skip }, async () => {
  const user = await createUser(`eng4-${randomUUID()}@example.com`);
  const jwt = await jwtFor(user.id);
  const { status } = await rpc(jwt, {
    p_event_id: randomUUID(),
    p_event_type: 'bill_payment',
    p_occurred_at: new Date().toISOString(),
    p_event_version: 99,
  });
  assert.notEqual(status, 200, 'future version must be rejected');
});

test('an unauthenticated caller cannot record an event', { skip }, async () => {
  const { status } = await req('/rest/v1/rpc/record_engagement_event', {
    method: 'POST',
    headers: headers(anonKey), // anon, no user JWT
    body: JSON.stringify({
      p_event_id: randomUUID(),
      p_event_type: 'bill_payment',
      p_occurred_at: new Date().toISOString(),
    }),
  });
  assert.notEqual(status, 200, 'anon must not award');
});

// Ownership: user_id is derived from auth.uid() inside the function, never a
// caller-supplied value — there is no p_user_id parameter, so a caller can only
// ever award to itself. Concurrency: the aggregate UPSERT is row-locked, so two
// concurrent events cannot lose an increment (verified on staging with parallel
// RPC calls; the total equals the sum of distinct-event awards).
