import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { bumpCaptureEndpointRateLimit, readBoundedJsonBody, readGeneration } from './capture_auth.ts';

// MALI-060n — the bounded body reader must not trust Content-Length and must
// count ACTUAL bytes (multi-byte UTF-8 aware) before decoding/parsing.
const jsonReq = (body: string, headers: Record<string, string> = { 'content-type': 'application/json' }) =>
  new Request('https://x/process', { method: 'POST', headers, body });

Deno.test('readBoundedJsonBody accepts a small valid JSON body', async () => {
  const r = await readBoundedJsonBody(jsonReq(JSON.stringify({ a: 1, b: 'ok' })), 1024);
  assertEquals(r.ok, true);
  if (r.ok) assertEquals(r.body.b, 'ok');
});

Deno.test('readBoundedJsonBody rejects an oversized body by ACTUAL bytes', async () => {
  const big = JSON.stringify({ t: 'x'.repeat(5000) });
  const r = await readBoundedJsonBody(jsonReq(big), 1024);
  assertEquals(r.ok, false);
  if (!r.ok) assertEquals(r.reason, 'too_large');
});

Deno.test('readBoundedJsonBody counts multi-byte UTF-8 at the byte boundary', async () => {
  // 400 Arabic chars = 800 UTF-8 bytes (2 bytes each), well over a 300-byte cap
  // even though the CHARACTER count is under it — proves byte-counting, not
  // char-counting, and that a forged small Content-Length can't sneak past.
  const body = JSON.stringify({ t: 'ن'.repeat(400) });
  const forgedLen = jsonReq(body, { 'content-type': 'application/json', 'content-length': '20' });
  const r = await readBoundedJsonBody(forgedLen, 300);
  assertEquals(r.ok, false);
  if (!r.ok) assertEquals(r.reason, 'too_large');
});

Deno.test('readBoundedJsonBody rejects malformed JSON', async () => {
  const r = await readBoundedJsonBody(jsonReq('{ not json'), 1024);
  assertEquals(r.ok, false);
  if (!r.ok) assertEquals(r.reason, 'invalid_json');
});

Deno.test('readBoundedJsonBody rejects a non-JSON content type', async () => {
  const r = await readBoundedJsonBody(jsonReq('hello', { 'content-type': 'text/plain' }), 1024);
  assertEquals(r.ok, false);
  if (!r.ok) assertEquals(r.reason, 'unsupported_media_type');
});

Deno.test('bumpCaptureEndpointRateLimit namespaces endpoint keys', async () => {
  let params: Record<string, unknown> | undefined;
  const supabase = {
    rpc(_name: string, value: Record<string, unknown>) {
      params = value;
      return Promise.resolve({ data: false, error: null });
    },
  };

  const limited = await bumpCaptureEndpointRateLimit(
    supabase as never,
    'install-hash',
    'sync-captures',
    240,
  );

  assertEquals(limited, false);
  assertEquals(params, {
    p_install_id_hash: 'install-hash:sync-captures',
    p_limit: 240,
  });
});

// T-S7: verifyDevice is the single device-credential check behind process-ios-sms,
// sync-captures, link-capture-device, unlink-capture-device and register-push-token.
function deviceClient(row: Record<string, unknown> | null) {
  const updates: unknown[] = [];
  const builder: Record<string, unknown> = {};
  builder.select = () => builder;
  builder.eq = () => builder;
  builder.maybeSingle = () => Promise.resolve({ data: row, error: null });
  builder.update = (v: unknown) => {
    updates.push(v);
    return builder;
  };
  builder.then = (resolve: (v: unknown) => unknown) => Promise.resolve({ data: null, error: null }).then(resolve);
  return { updates, client: { from: () => builder } as never };
}

Deno.test('T-S7 verifyDevice refuses a revoked device with the right secret (401 credential_revoked), no liveness touch', async () => {
  const { sha256Hex, verifyDevice } = await import('./capture_auth.ts');
  const f = deviceClient({
    device_secret_hash: await sha256Hex('sec'),
    user_id: 'u',
    revoked_at: '2026-09-01T00:00:00Z',
  });
  const r = await verifyDevice(f.client, 'install', 'sec');
  assertEquals(r, { ok: false, status: 401, error: 'credential_revoked' });
  assertEquals(f.updates.length, 0);
});

Deno.test('T-S7 verifyDevice: wrong secret on a revoked device does not reveal revocation', async () => {
  const { sha256Hex, verifyDevice } = await import('./capture_auth.ts');
  const f = deviceClient({
    device_secret_hash: await sha256Hex('sec'),
    user_id: 'u',
    revoked_at: '2026-09-01T00:00:00Z',
  });
  const r = await verifyDevice(f.client, 'install', 'WRONG');
  assertEquals(r, { ok: false, status: 401, error: 'invalid_device_secret' });
});

Deno.test('verifyDevice accepts an unrevoked device and returns its user', async () => {
  const { sha256Hex, verifyDevice } = await import('./capture_auth.ts');
  const f = deviceClient({ device_secret_hash: await sha256Hex('sec'), user_id: 'u', revoked_at: null });
  const r = await verifyDevice(f.client, 'install', 'sec');
  assertEquals(r.ok && r.userId, 'u');
});

Deno.test('T-S7 every device-authenticated endpoint goes through a revoked-aware check', async () => {
  const root = new URL('../', import.meta.url);
  for (
    const fn of [
      'process-ios-sms',
      'sync-captures',
      'link-capture-device',
      'unlink-capture-device',
      'register-push-token',
    ]
  ) {
    const src = await Deno.readTextFile(new URL(`${fn}/index.ts`, root));
    assertEquals(/verifyDevice\(|dependencies\.verifyDevice\(/.test(src), true, fn);
  }
  // set-device-consent: legacy path uses resolveVerifiedIdentity (refuses revoked), v2 verifyDevice.
  const consent = await Deno.readTextFile(new URL('set-device-consent/index.ts', root));
  assertEquals(/resolveVerifiedIdentity/.test(consent) && /verifyDevice/.test(consent), true);
});

Deno.test('readGeneration: a non-negative safe integer under any key, else 0 (old clients send none)', () => {
  assertEquals(readGeneration({ client_generation: 7 }, 'client_generation', 'clientGeneration'), 7);
  assertEquals(readGeneration({ clientGeneration: 3 }, 'client_generation', 'clientGeneration'), 3);
  assertEquals(readGeneration({ client_generation: 0 }, 'client_generation'), 0);
  for (const bad of [-1, 1.5, '4', null, undefined, NaN, Infinity, 2 ** 60]) {
    assertEquals(readGeneration({ client_generation: bad }, 'client_generation'), 0, String(bad));
  }
  assertEquals(readGeneration({}, 'client_generation'), 0);
});
