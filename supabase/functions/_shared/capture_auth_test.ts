import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { bumpCaptureEndpointRateLimit, readBoundedJsonBody } from './capture_auth.ts';

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
