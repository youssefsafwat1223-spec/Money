// BEHAVIOURAL tests for register-device.
//
// This endpoint had no test of any kind, and the defect it was fixed for —
// a rotated secret inheriting an existing user link — is a property of what
// the upsert WRITES. A test that greps the source for `user_id` would pass
// against the broken version too, because the broken version's problem was
// the absence of that key. These drive the real handler against a fake
// Supabase and assert on the row that results.

import { assert, assertEquals } from 'jsr:@std/assert@1';
import { handleRegisterDevice } from './index.ts';

type Row = Record<string, unknown>;

/// Enough of the PostgREST builder chain for this handler, with the resulting
/// rows observable.
class FakeDb {
  devices: Row[] = [];
  /// The rate limiter's atomic path. `false` = under the limit.
  rateLimited = false;

  rpc(_fn: string, _args: unknown) {
    return Promise.resolve({ data: this.rateLimited, error: null });
  }

  from(table: string) {
    // deno-lint-ignore no-this-alias
    const db = this;
    if (table !== 'capture_devices') {
      // The rate-limit fallback table; `rpc` above answers first in practice.
      return {
        select: () => ({ eq: () => ({ eq: () => ({ maybeSingle: () => Promise.resolve({ data: null, error: null }) }) }) }),
        upsert: () => Promise.resolve({ data: null, error: null }),
      };
    }
    const filters: Array<[string, unknown]> = [];
    const api: Record<string, unknown> = {
      select() {
        return api;
      },
      eq(column: string, value: unknown) {
        filters.push([column, value]);
        return api;
      },
      maybeSingle() {
        const row = db.devices.find((r) => filters.every(([c, v]) => r[c] === v));
        return Promise.resolve({ data: row ?? null, error: null });
      },
      upsert(values: Row) {
        const i = db.devices.findIndex((r) => r.install_id_hash === values.install_id_hash);
        // PostgREST upsert writes exactly the supplied columns; anything
        // omitted keeps its previous value. Modelling that is the whole point
        // of this fake — the bug was an OMITTED column.
        if (i >= 0) db.devices[i] = { ...db.devices[i], ...values };
        else db.devices.push({ ...values });
        return Promise.resolve({ data: null, error: null });
      },
    };
    return api;
  }
}

function post(body: unknown): Request {
  return new Request('https://example.test/functions/v1/register-device', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
}

Deno.test('rotating a linked install CLEARS the user link', async () => {
  const db = new FakeDb();
  const res0 = await handleRegisterDevice(post({ installId: 'victim-install' }), () => db as never);
  assertEquals(res0.status, 200);
  // The victim then links, exactly as link-capture-device does.
  db.devices[0].user_id = 'victim-user';
  const firstSecret = db.devices[0].device_secret_hash;

  // The attacker presents the same installId with only the public anon key.
  const res = await handleRegisterDevice(post({ installId: 'victim-install' }), () => db as never);
  assertEquals(res.status, 200);

  assertEquals(
    db.devices[0].user_id,
    null,
    'a rotated secret must not inherit the previous user link — sync-captures ' +
      'would otherwise serve that user rows to whoever rotated',
  );
  assert(db.devices[0].device_secret_hash !== firstSecret, 'the secret must actually rotate');
});

Deno.test('rotation preserves created_at and does not clear revoked_at', async () => {
  const db = new FakeDb();
  await handleRegisterDevice(post({ installId: 'i' }), () => db as never);
  const createdAt = db.devices[0].created_at;
  // Revocation is an operator action and must survive a device-owner rotation.
  db.devices[0].revoked_at = '2026-01-01T00:00:00.000Z';

  await handleRegisterDevice(post({ installId: 'i' }), () => db as never);
  assertEquals(db.devices[0].created_at, createdAt);
  assertEquals(db.devices[0].revoked_at, '2026-01-01T00:00:00.000Z');
});

Deno.test('a first registration inserts an unlinked row', async () => {
  const db = new FakeDb();
  const res = await handleRegisterDevice(post({ installId: 'fresh', platform: 'android' }), () => db as never);
  assertEquals(res.status, 200);
  const payload = await res.json() as Record<string, unknown>;
  assertEquals(typeof payload.deviceSecret, 'string');
  assertEquals((payload.deviceSecret as string).length, 64);
  assertEquals(db.devices.length, 1);
  assertEquals(db.devices[0].user_id, null);
  assertEquals(db.devices[0].platform, 'android');
});

Deno.test('a missing installId is refused before any write', async () => {
  const db = new FakeDb();
  const res = await handleRegisterDevice(post({}), () => db as never);
  assertEquals(res.status, 400);
  assertEquals(await res.json(), { error: 'missing_install_id' });
  assertEquals(db.devices.length, 0);
});

Deno.test('a non-POST method is refused', async () => {
  const db = new FakeDb();
  const res = await handleRegisterDevice(
    new Request('https://example.test/functions/v1/register-device', { method: 'GET' }),
    () => db as never,
  );
  assertEquals(res.status, 405);
});

Deno.test('an install over the daily limit is refused before any write', async () => {
  const db = new FakeDb();
  db.rateLimited = true;
  const res = await handleRegisterDevice(post({ installId: 'noisy' }), () => db as never);
  assertEquals(res.status, 429);
  assertEquals(db.devices.length, 0);
});
