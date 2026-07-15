import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import test from 'node:test';

const supabaseUrl = process.env.SUPABASE_URL;
const anonKey = process.env.SUPABASE_ANON_KEY;
const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;

const liveTest =
  Boolean(supabaseUrl) && Boolean(anonKey) && Boolean(serviceRoleKey);

function headers(key, jwt = key) {
  return {
    apikey: key,
    authorization: `Bearer ${jwt}`,
    'content-type': 'application/json',
  };
}

async function request(path, options) {
  const response = await fetch(`${supabaseUrl}${path}`, options);
  const text = await response.text();
  const body = text ? JSON.parse(text) : null;
  return { response, body };
}

async function createUser(email, password) {
  const { response, body } = await request('/auth/v1/admin/users', {
    method: 'POST',
    headers: headers(serviceRoleKey),
    body: JSON.stringify({ email, password, email_confirm: true }),
  });
  assert.equal(response.status, 200, JSON.stringify(body));
  return body;
}

async function signIn(email, password) {
  const { response, body } = await request(
    '/auth/v1/token?grant_type=password',
    {
      method: 'POST',
      headers: headers(anonKey),
      body: JSON.stringify({ email, password }),
    },
  );
  assert.equal(response.status, 200, JSON.stringify(body));
  return body.access_token;
}

async function deleteUser(userId) {
  const { response } = await request(`/auth/v1/admin/users/${userId}`, {
    method: 'DELETE',
    headers: headers(serviceRoleKey),
  });
  assert.ok(response.status === 200 || response.status === 404);
}

async function callRpc(jwt, name, body = {}) {
  return request(`/rest/v1/rpc/${name}`, {
    method: 'POST',
    headers: headers(anonKey, jwt),
    body: JSON.stringify(body),
  });
}

async function profileDeleteScheduledAt(userId) {
  const { body } = await request(
    `/rest/v1/profiles?id=eq.${userId}&select=delete_scheduled_at`,
    { headers: headers(serviceRoleKey) },
  );
  return body?.[0]?.delete_scheduled_at ?? null;
}

test(
  'request_account_deletion is idempotent and does not push the clock forward',
  { skip: liveTest ? false : 'requires SUPABASE_URL, SUPABASE_ANON_KEY, and SUPABASE_SERVICE_ROLE_KEY' },
  async () => {
    const suffix = randomUUID();
    const email = `qa-delete-policy-${suffix}@example.invalid`;
    const password = `Qa-delete-policy-${suffix}!`;
    let userId;
    try {
      const user = await createUser(email, password);
      userId = user.id;
      const jwt = await signIn(email, password);

      const first = await callRpc(jwt, 'request_account_deletion');
      assert.equal(first.response.status, 200, JSON.stringify(first.body));
      const firstScheduled = first.body;
      assert.ok(firstScheduled, 'expected a scheduled timestamp');

      // Second call while already scheduled must return the SAME timestamp,
      // not push it forward — this is the core idempotency guarantee.
      await new Promise((resolve) => setTimeout(resolve, 1100));
      const second = await callRpc(jwt, 'request_account_deletion');
      assert.equal(second.response.status, 200, JSON.stringify(second.body));
      assert.equal(second.body, firstScheduled);

      const stored = await profileDeleteScheduledAt(userId);
      assert.equal(stored, firstScheduled);

      // Cancellation clears it. A `returns void` RPC yields 204 No Content
      // via PostgREST, not 200 — that's correct, not an error.
      const cancelled = await callRpc(jwt, 'cancel_account_deletion');
      assert.equal(cancelled.response.status, 204, JSON.stringify(cancelled.body));
      const afterCancel = await profileDeleteScheduledAt(userId);
      assert.equal(afterCancel, null);

      // Cancelling again with nothing scheduled is a safe no-op.
      const cancelAgain = await callRpc(jwt, 'cancel_account_deletion');
      assert.equal(cancelAgain.response.status, 204, JSON.stringify(cancelAgain.body));
    } finally {
      if (userId) await deleteUser(userId);
    }
  },
);

test(
  'request_account_deletion is rejected for an unauthenticated caller',
  { skip: liveTest ? false : 'requires SUPABASE_URL, SUPABASE_ANON_KEY, and SUPABASE_SERVICE_ROLE_KEY' },
  async () => {
    const { response, body } = await callRpc(anonKey, 'request_account_deletion');
    assert.equal(response.status, 401, JSON.stringify(body));
  },
);

test(
  'purge_user_data removes every row for the target user and nothing else',
  { skip: liveTest ? false : 'requires SUPABASE_URL, SUPABASE_ANON_KEY, and SUPABASE_SERVICE_ROLE_KEY' },
  async () => {
    const suffixA = randomUUID();
    const suffixB = randomUUID();
    const emailA = `qa-purge-a-${suffixA}@example.invalid`;
    const emailB = `qa-purge-b-${suffixB}@example.invalid`;
    let userIdA;
    let userIdB;
    try {
      const userA = await createUser(emailA, 'Qa-purge-a-12345!');
      userIdA = userA.id;
      const userB = await createUser(emailB, 'Qa-purge-b-12345!');
      userIdB = userB.id;

      const now = new Date().toISOString();
      const seedAccount = async (userId, localId) => {
        const { response, body } = await request('/rest/v1/user_accounts', {
          method: 'POST',
          headers: { ...headers(serviceRoleKey), prefer: 'return=representation' },
          body: JSON.stringify({
            user_id: userId,
            local_id: localId,
            name: 'QA Purge Account',
            currency: 'SAR',
            type: 'bank',
            initial_balance: 0,
            current_balance: 0,
            is_default: true,
            sort_order: 0,
            created_at: now,
            updated_at: now,
          }),
        });
        assert.equal(response.status, 201, JSON.stringify(body));
        return body[0].id;
      };

      await seedAccount(userIdA, `qa-purge-a-${suffixA}`);
      const accountB = await seedAccount(userIdB, `qa-purge-b-${suffixB}`);

      // Purge only A.
      const purge = await request('/rest/v1/rpc/purge_user_data', {
        method: 'POST',
        headers: headers(serviceRoleKey),
        body: JSON.stringify({ p_user_id: userIdA }),
      });
      assert.equal(purge.response.status, 204, JSON.stringify(purge.body));

      const remainingA = await request(
        `/rest/v1/user_accounts?user_id=eq.${userIdA}&select=id`,
        { headers: headers(serviceRoleKey) },
      );
      assert.equal(remainingA.body.length, 0);

      const remainingProfileA = await request(
        `/rest/v1/profiles?id=eq.${userIdA}&select=id`,
        { headers: headers(serviceRoleKey) },
      );
      assert.equal(remainingProfileA.body.length, 0);

      // B is completely untouched.
      const remainingB = await request(
        `/rest/v1/user_accounts?user_id=eq.${userIdB}&select=id`,
        { headers: headers(serviceRoleKey) },
      );
      assert.equal(remainingB.body.length, 1);
      assert.equal(remainingB.body[0].id, accountB);
    } finally {
      if (userIdA) await deleteUser(userIdA);
      if (userIdB) {
        await request(`/rest/v1/user_accounts?user_id=eq.${userIdB}`, {
          method: 'DELETE',
          headers: headers(serviceRoleKey),
        });
        await deleteUser(userIdB);
      }
    }
  },
);

test(
  'purge_user_data is rejected for a non-service-role caller',
  { skip: liveTest ? false : 'requires SUPABASE_URL, SUPABASE_ANON_KEY, and SUPABASE_SERVICE_ROLE_KEY' },
  async () => {
    const suffix = randomUUID();
    const email = `qa-purge-authz-${suffix}@example.invalid`;
    const password = `Qa-purge-authz-${suffix}!`;
    let userId;
    try {
      const user = await createUser(email, password);
      userId = user.id;
      const jwt = await signIn(email, password);

      const { response, body } = await request('/rest/v1/rpc/purge_user_data', {
        method: 'POST',
        headers: headers(anonKey, jwt),
        body: JSON.stringify({ p_user_id: userId }),
      });
      assert.ok(response.status === 401 || response.status === 403, JSON.stringify(body));
    } finally {
      if (userId) await deleteUser(userId);
    }
  },
);
