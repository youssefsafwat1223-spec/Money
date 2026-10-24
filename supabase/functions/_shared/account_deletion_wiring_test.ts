import { assert, assertEquals, assertFalse, assertRejects } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { createChallengePort, resolveDeletionCollaborators } from './account_deletion_wiring.ts';
import type { RpcClient, RpcResult } from './account_deletion_adapter.ts';

const kp = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
const der = new Uint8Array(await crypto.subtle.exportKey('pkcs8', kp.privateKey));
const P8 = `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...der))}\n-----END PRIVATE KEY-----`;
const SEALER = btoa(String.fromCharCode(...new Uint8Array(32).fill(3)));
const GOOD: Record<string, string> = {
  APPLE_TEAM_ID: 'TEAM123456',
  APPLE_KEY_ID: 'KEYID12345',
  APPLE_CLIENT_ID: 'com.example.qirsh',
  APPLE_PRIVATE_KEY_P8: P8,
  ACCOUNT_DELETION_SEALER_KEY: SEALER,
};
const rpc: RpcClient = { rpc: () => Promise.resolve({ data: null, error: null }) };
const resolve = (env: Record<string, string>) =>
  resolveDeletionCollaborators({ env: (k) => env[k], fetch: (() => Promise.reject(new Error('net'))) as typeof fetch, now: () => 0, rpc });

Deno.test('all five secrets present and well-formed: ready, real sealer round-trips', async () => {
  const c = await resolve(GOOD);
  assert(c.ready);
  assertEquals(await c.sealer.unseal(await c.sealer.seal('tok')), 'tok');
});

Deno.test('any missing or malformed secret keeps the stubs and ready=false (fail closed)', async () => {
  const bad: Record<string, string> = {
    APPLE_TEAM_ID: 'x',
    APPLE_KEY_ID: '',
    APPLE_CLIENT_ID: '',
    APPLE_PRIVATE_KEY_P8: '-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----',
    ACCOUNT_DELETION_SEALER_KEY: btoa('short'),
  };
  for (const k of Object.keys(GOOD)) {
    const missing = { ...GOOD };
    delete missing[k];
    const m = await resolve(missing);
    assertFalse(m.ready, `missing ${k}`);
    const w = await resolve({ ...GOOD, [k]: bad[k] });
    assertFalse(w.ready, `malformed ${k}`);
    assertEquals(await w.apple.authorize({ uid: 'u', challengeId: 'c', challengeResponse: '{}' }), { status: 'not_configured' });
    assertEquals(await w.apple.revoke('t'), 'retryable');
    await assertRejects(() => w.sealer.seal('x'), Error, 'sealer_not_configured');
  }
});

const rpcWith = (res: RpcResult): RpcClient => ({ rpc: () => Promise.resolve(res) });
const portOf = (res: RpcResult) =>
  createChallengePort({ rpc: rpcWith(res), getUser: () => Promise.resolve({ id: 'u' }), isAdmin: () => Promise.resolve(false) });

Deno.test('challenge port maps issuer results and SQLSTATEs', async () => {
  assertEquals(
    await portOf({ data: { challenge_id: 'c', nonce: 'n', expires_at_ms: 9 }, error: null }).issue('u'),
    { outcome: 'issued', challengeId: 'c', nonce: 'n', expiresAtMs: 9 },
  );
  assertEquals(
    await portOf({ data: [{ challenge_id: 'c', nonce: 'n', expires_at: '2026-10-24T00:00:00Z' }], error: null }).issue('u'),
    { outcome: 'issued', challengeId: 'c', nonce: 'n', expiresAtMs: Date.parse('2026-10-24T00:00:00Z') },
  );
  assertEquals(await portOf({ data: null, error: { code: 'QD031' } }).issue('u'), { outcome: 'admin' });
  assertEquals(await portOf({ data: null, error: { code: 'QD032' } }).issue('u'), { outcome: 'rate_limited' });
  assertEquals(await portOf({ data: null, error: { code: 'already_pending' } }).issue('u'), { outcome: 'already_pending' });
  assertEquals(await portOf({ data: { outcome: 'already_pending' }, error: null }).issue('u'), { outcome: 'already_pending' });
  await assertRejects(() => portOf({ data: null, error: { code: 'XX000' } }).issue('u'));
  await assertRejects(() => portOf({ data: { nonce: 'n' }, error: null }).issue('u'));
  await assertRejects(() => portOf({ data: { challenge_id: 'c', nonce: 'n' }, error: null }).issue('u'));
});
