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
    body: JSON.stringify({
      email,
      password,
      email_confirm: true,
      user_metadata: { purpose: 'delete_user_account_safely_concurrency_test' },
    }),
  });
  assert.equal(response.status, 200, JSON.stringify(body));
  return body;
}

async function signIn(email, password) {
  const { response, body } = await request('/auth/v1/token?grant_type=password', {
    method: 'POST',
    headers: headers(anonKey),
    body: JSON.stringify({ email, password }),
  });
  assert.equal(response.status, 200, JSON.stringify(body));
  return body.access_token;
}

async function deleteUser(userId) {
  const { response, body } = await request(`/auth/v1/admin/users/${userId}`, {
    method: 'DELETE',
    headers: headers(serviceRoleKey),
  });
  assert.ok(
    response.status === 200 || response.status === 404,
    JSON.stringify(body),
  );
}

async function seedAccounts(userId) {
  const accountIds = [randomUUID(), randomUUID()];
  const now = new Date().toISOString();
  const rows = accountIds.map((id, index) => ({
    id,
    user_id: userId,
    local_id: `qa-delete-race-${index}-${randomUUID()}`,
    name: `QA Delete Race ${index + 1}`,
    currency: 'SAR',
    type: 'bank',
    initial_balance: 0,
    current_balance: 0,
    is_default: index === 0,
    sort_order: index,
    created_at: now,
    updated_at: now,
  }));
  const { response, body } = await request('/rest/v1/user_accounts', {
    method: 'POST',
    headers: {
      ...headers(serviceRoleKey),
      prefer: 'return=representation',
    },
    body: JSON.stringify(rows),
  });
  assert.equal(response.status, 201, JSON.stringify(body));
  assert.equal(body.length, 2);
  return accountIds;
}

async function activeAccountCount(userId) {
  const query = new URLSearchParams({
    user_id: `eq.${userId}`,
    deleted_at: 'is.null',
    select: 'id',
  });
  const { response, body } = await request(`/rest/v1/user_accounts?${query}`, {
    method: 'GET',
    headers: headers(serviceRoleKey),
  });
  assert.equal(response.status, 200, JSON.stringify(body));
  return body.length;
}

async function allAccountCount(userId) {
  const query = new URLSearchParams({
    user_id: `eq.${userId}`,
    select: 'id',
  });
  const { response, body } = await request(`/rest/v1/user_accounts?${query}`, {
    method: 'GET',
    headers: headers(serviceRoleKey),
  });
  assert.equal(response.status, 200, JSON.stringify(body));
  return body.length;
}

async function hardDeleteAccounts(userId) {
  const query = new URLSearchParams({ user_id: `eq.${userId}` });
  const { response, body } = await request(`/rest/v1/user_accounts?${query}`, {
    method: 'DELETE',
    headers: headers(serviceRoleKey),
  });
  assert.ok(
    response.status === 200 || response.status === 204,
    JSON.stringify(body),
  );
}

async function deleteSafely(jwt, accountId) {
  const { response, body } = await request(
    '/rest/v1/rpc/delete_user_account_safely',
    {
      method: 'POST',
      headers: headers(anonKey, jwt),
      body: JSON.stringify({ p_account_id: accountId }),
    },
  );
  return { ok: response.ok, status: response.status, body };
}

test(
  'delete_user_account_safely serializes concurrent last-account deletion',
  { skip: liveTest ? false : 'requires SUPABASE_URL, SUPABASE_ANON_KEY, and SUPABASE_SERVICE_ROLE_KEY' },
  async () => {
    const suffix = randomUUID();
    const email = `qa-delete-race-${suffix}@example.invalid`;
    const password = `Qa-delete-race-${suffix}!`;
    let userId;

    try {
      const user = await createUser(email, password);
      userId = user.id;
      const jwt = await signIn(email, password);
      const accountIds = await seedAccounts(userId);

      assert.equal(await activeAccountCount(userId), 2);

      const results = await Promise.all([
        deleteSafely(jwt, accountIds[0]),
        deleteSafely(jwt, accountIds[1]),
      ]);

      const successes = results.filter((result) => result.ok);
      const failures = results.filter((result) => !result.ok);
      assert.equal(successes.length, 1, JSON.stringify(results));
      assert.equal(failures.length, 1, JSON.stringify(results));
      assert.equal(failures[0].body?.code, '23514', JSON.stringify(results));
      assert.match(failures[0].body?.message ?? '', /last_account/);
      assert.equal(await activeAccountCount(userId), 1);
    } finally {
      if (userId) {
        await hardDeleteAccounts(userId);
        assert.equal(await allAccountCount(userId), 0);
        await deleteUser(userId);
      }
    }
  },
);
