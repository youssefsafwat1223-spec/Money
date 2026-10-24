import { assert, assertEquals, assertFalse, assertRejects } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { createAppleDeletionGateway, parseAppleDeletionConfig } from './apple_deletion_gateway.ts';
import { b64urlDecode, b64urlEncode } from './material_sealer.ts';

const UID = '11111111-1111-4111-8111-111111111111';
const CHALLENGE_ID = 'challenge-0001';
const NONCE_HASH = 'ab'.repeat(32);
const CLIENT_ID = 'com.example.qirsh';
const TEAM = 'TEAM123456';
const KEY_ID = 'KEYID12345';
const SUB = '001234.abcdef.5678';
const NOW = 1_800_000_000_000;
const enc = new TextEncoder();

// ── test key material, generated in-test ─────────────────────────────────────
const rsa = await crypto.subtle.generateKey(
  { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' },
  true,
  ['sign', 'verify'],
);
const ec = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
const p8 = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);

async function pem(key: CryptoKey): Promise<string> {
  const der = new Uint8Array(await crypto.subtle.exportKey('pkcs8', key));
  let bin = '';
  for (const b of der) bin += String.fromCharCode(b);
  const b64 = btoa(bin).replace(/(.{64})/g, '$1\n');
  return `-----BEGIN PRIVATE KEY-----\n${b64}\n-----END PRIVATE KEY-----`;
}
const P8_PEM = await pem(p8.privateKey);

const rsaJwk = { ...(await crypto.subtle.exportKey('jwk', rsa.publicKey)), kid: 'rsa-1', alg: 'RS256', use: 'sig' };
const ecJwk = { ...(await crypto.subtle.exportKey('jwk', ec.publicKey)), kid: 'ec-1', alg: 'ES256', use: 'sig' };

async function signJwt(
  header: Record<string, unknown>,
  claims: Record<string, unknown>,
  key: CryptoKey,
  alg: 'RS256' | 'ES256',
): Promise<string> {
  const input = `${b64urlEncode(enc.encode(JSON.stringify(header)))}.${b64urlEncode(enc.encode(JSON.stringify(claims)))}`;
  const sig = new Uint8Array(
    await crypto.subtle.sign(alg === 'RS256' ? { name: 'RSASSA-PKCS1-v1_5' } : { name: 'ECDSA', hash: 'SHA-256' }, key, enc.encode(input)),
  );
  return `${input}.${b64urlEncode(sig)}`;
}

// Exchange id_tokens are not re-verified; only the payload's sub is read.
const unsignedJwt = (claims: Record<string, unknown>) =>
  `${b64urlEncode(enc.encode('{"alg":"none"}'))}.${b64urlEncode(enc.encode(JSON.stringify(claims)))}.sig`;

const goodClaims = () => ({
  iss: 'https://appleid.apple.com',
  aud: CLIENT_ID,
  sub: SUB,
  nonce: NONCE_HASH,
  iat: Math.floor(NOW / 1000),
  exp: Math.floor(NOW / 1000) + 600,
});
const idToken = (over: Record<string, unknown> = {}, kid = 'rsa-1') =>
  signJwt({ alg: 'RS256', kid }, { ...goodClaims(), ...over }, rsa.privateKey, 'RS256');

// ── fakes ────────────────────────────────────────────────────────────────────
type Fx = {
  challenge: unknown;
  subject: unknown;
  jwksStatus: number;
  jwks: unknown;
  tokenResponse: () => Response | Promise<Response>;
  revokeResponse: () => Response | Promise<Response>;
  now: number;
  calls: { url: string; body: string; signal?: AbortSignal | null }[];
  rpcCalls: { fn: string; args: Record<string, unknown> }[];
  rpcError: boolean;
};

function fixture(over: Partial<Fx> = {}) {
  const fx: Fx = {
    challenge: { nonce_hash: NONCE_HASH, expires_at_ms: NOW + 120_000, consumed: false },
    subject: SUB,
    jwksStatus: 200,
    jwks: { keys: [rsaJwk, ecJwk] },
    tokenResponse: () => Response.json({ refresh_token: 'r.refresh-secret', access_token: 'a', id_token: unsignedJwt({ sub: SUB }) }),
    revokeResponse: () => new Response('', { status: 200 }),
    now: NOW,
    calls: [],
    rpcCalls: [],
    rpcError: false,
    ...over,
  };
  const stubFetch = (async (input: string | URL | Request, init?: RequestInit) => {
    const url = String(input);
    fx.calls.push({ url, body: String(init?.body ?? ''), signal: init?.signal });
    if (url === 'https://appleid.apple.com/auth/keys') {
      return fx.jwksStatus === 200 ? Response.json(fx.jwks) : new Response('x', { status: fx.jwksStatus });
    }
    if (url === 'https://appleid.apple.com/auth/token') return await fx.tokenResponse();
    if (url === 'https://appleid.apple.com/auth/revoke') return await fx.revokeResponse();
    throw new Error('unexpected_url');
  }) as typeof fetch;
  const rpc = {
    rpc: (fn: string, args: Record<string, unknown>) => {
      fx.rpcCalls.push({ fn, args });
      if (fx.rpcError) return Promise.resolve({ data: null, error: { code: 'XX000' } });
      if (fn === 'account_deletion_read_challenge') return Promise.resolve({ data: fx.challenge, error: null });
      if (fn === 'account_deletion_apple_subject') return Promise.resolve({ data: fx.subject, error: null });
      return Promise.resolve({ data: null, error: { code: 'unknown_fn' } });
    },
  };
  const gw = createAppleDeletionGateway({
    fetch: stubFetch,
    now: () => fx.now,
    rpc,
    config: { teamId: TEAM, keyId: KEY_ID, clientId: CLIENT_ID, privateKeyP8: P8_PEM },
  });
  return { fx, gw };
}

const response = (identity: string, code = 'auth-code-1') =>
  JSON.stringify({ identity_token: identity, authorization_code: code });
const authorize = (gw: ReturnType<typeof fixture>['gw'], challengeResponse: string) =>
  gw.authorize({ uid: UID, challengeId: CHALLENGE_ID, challengeResponse });

// ── authorize: success ───────────────────────────────────────────────────────
Deno.test('valid RS256 token: subject matches, code exchanged, refresh token and challenge expiry returned', async () => {
  const { fx, gw } = fixture();
  const r = await authorize(gw, response(await idToken()));
  assertEquals(r, { status: 'ok', refreshToken: 'r.refresh-secret', challengeExpiresAtMs: NOW + 120_000 });
  const readCall = fx.rpcCalls.find((c) => c.fn === 'account_deletion_read_challenge')!;
  assertEquals(readCall.args, { p_uid: UID, p_challenge_id: CHALLENGE_ID });
  assertEquals(fx.rpcCalls.find((c) => c.fn === 'account_deletion_apple_subject')!.args, { p_uid: UID });
});

Deno.test('valid ES256 token (EC JWKS entry) is also accepted', async () => {
  const { gw } = fixture();
  const t = await signJwt({ alg: 'ES256', kid: 'ec-1' }, goodClaims(), ec.privateKey, 'ES256');
  assertEquals((await authorize(gw, response(t))).status, 'ok');
});

Deno.test('client secret is an ES256 JWT with the contract claims, lifetime <= 5 min, verifiable with the P8 public key', async () => {
  const { fx, gw } = fixture();
  await authorize(gw, response(await idToken(), 'the-code'));
  const call = fx.calls.find((c) => c.url.endsWith('/auth/token'))!;
  const form = new URLSearchParams(call.body);
  assertEquals(form.get('grant_type'), 'authorization_code');
  assertEquals(form.get('code'), 'the-code');
  assertEquals(form.get('client_id'), CLIENT_ID);
  const secret = form.get('client_secret')!;
  const [h, p, s] = secret.split('.');
  const header = JSON.parse(new TextDecoder().decode(b64urlDecode(h)));
  const claims = JSON.parse(new TextDecoder().decode(b64urlDecode(p)));
  assertEquals(header.alg, 'ES256');
  assertEquals(header.kid, KEY_ID);
  assertEquals(claims.iss, TEAM);
  assertEquals(claims.sub, CLIENT_ID);
  assertEquals(claims.aud, 'https://appleid.apple.com');
  assert(claims.exp - claims.iat <= 300 && claims.exp > claims.iat);
  assert(await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, p8.publicKey, b64urlDecode(s) as BufferSource, enc.encode(`${h}.${p}`)));
});

// ── authorize: challenge handling ────────────────────────────────────────────
Deno.test('malformed challenge_response is challenge_invalid without touching RPC or network', async () => {
  const { fx, gw } = fixture();
  for (const bad of ['not json', '[]', '{}', JSON.stringify({ identity_token: 'x' }), JSON.stringify({ identity_token: '', authorization_code: 'c' }), JSON.stringify({ identity_token: 1, authorization_code: 'c' })]) {
    assertEquals(await authorize(gw, bad), { status: 'challenge_invalid' });
  }
  assertEquals(fx.rpcCalls.length + fx.calls.length, 0);
});

Deno.test('challenge not found, consumed and expired map to invalid, replayed and expired', async () => {
  const t = await idToken();
  assertEquals(await authorize(fixture({ challenge: null }).gw, response(t)), { status: 'challenge_invalid' });
  assertEquals(await authorize(fixture({ challenge: [] }).gw, response(t)), { status: 'challenge_invalid' });
  assertEquals(
    await authorize(fixture({ challenge: { nonce_hash: NONCE_HASH, expires_at_ms: NOW + 1000, consumed: true } }).gw, response(t)),
    { status: 'challenge_replayed' },
  );
  assertEquals(
    await authorize(fixture({ challenge: { nonce_hash: NONCE_HASH, expires_at_ms: NOW - 1, consumed: false } }).gw, response(t)),
    { status: 'challenge_expired' },
  );
});

Deno.test('a failing or malformed challenge read is an outage (throw), never a verdict', async () => {
  const t = await idToken();
  await assertRejects(() => authorize(fixture({ rpcError: true }).gw, response(t)));
  await assertRejects(() => authorize(fixture({ challenge: { nonce_hash: 5 } }).gw, response(t)));
});

// ── authorize: identity token verification ───────────────────────────────────
Deno.test('wrong audience, issuer or nonce is challenge_invalid and never exchanges the code', async () => {
  for (const over of [{ aud: 'com.other.app' }, { aud: [CLIENT_ID, 'x'] }, { iss: 'https://evil.example' }, { nonce: 'cd'.repeat(32) }, { nonce: undefined }]) {
    const { fx, gw } = fixture();
    assertEquals(await authorize(gw, response(await idToken(over))), { status: 'challenge_invalid' }, JSON.stringify(over));
    assertFalse(fx.calls.some((c) => c.url.endsWith('/auth/token')));
  }
});

Deno.test('expired token is rejected beyond 60 s skew and accepted within it', async () => {
  const exp = (offsetS: number) => ({ exp: Math.floor(NOW / 1000) + offsetS });
  assertEquals(await authorize(fixture().gw, response(await idToken(exp(-120)))), { status: 'challenge_invalid' });
  assertEquals(await authorize(fixture().gw, response(await idToken(exp(-61)))), { status: 'challenge_invalid' });
  assertEquals((await authorize(fixture().gw, response(await idToken(exp(-30))))).status, 'ok');
  assertEquals(await authorize(fixture().gw, response(await idToken({ exp: 'soon' }))), { status: 'challenge_invalid' });
});

Deno.test('bad signature, wrong key, alg confusion and garbage tokens are challenge_invalid', async () => {
  const good = await idToken();
  const [h, p, s] = good.split('.');
  const wrongSig = `${h}.${p}.${s.slice(0, -4)}AAAA`;
  assertEquals(await authorize(fixture().gw, response(wrongSig)), { status: 'challenge_invalid' });
  // payload swapped under the original signature
  const forgedPayload = b64urlEncode(enc.encode(JSON.stringify({ ...goodClaims(), sub: 'attacker' })));
  assertEquals(await authorize(fixture().gw, response(`${h}.${forgedPayload}.${s}`)), { status: 'challenge_invalid' });
  // signed by a different RSA key under the trusted kid
  const other = await crypto.subtle.generateKey(
    { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' },
    true,
    ['sign', 'verify'],
  );
  const forged = await signJwt({ alg: 'RS256', kid: 'rsa-1' }, goodClaims(), other.privateKey, 'RS256');
  assertEquals(await authorize(fixture().gw, response(forged)), { status: 'challenge_invalid' });
  // alg none / HS256 / alg that does not match the key type
  const none = `${b64urlEncode(enc.encode('{"alg":"none","kid":"rsa-1"}'))}.${p}.`;
  assertEquals(await authorize(fixture().gw, response(none)), { status: 'challenge_invalid' });
  const hs = `${b64urlEncode(enc.encode('{"alg":"HS256","kid":"rsa-1"}'))}.${p}.${s}`;
  assertEquals(await authorize(fixture().gw, response(hs)), { status: 'challenge_invalid' });
  const esOnRsa = await signJwt({ alg: 'ES256', kid: 'rsa-1' }, goodClaims(), ec.privateKey, 'ES256');
  assertEquals(await authorize(fixture().gw, response(esOnRsa)), { status: 'challenge_invalid' });
  for (const junk of ['a.b', 'a.b.c', '...', 'x']) assertEquals(await authorize(fixture().gw, response(junk)), { status: 'challenge_invalid' });
});

Deno.test('unknown kid is challenge_invalid (no refetch inside 60 s) and JWKS is cached for an hour', async () => {
  const { fx, gw } = fixture();
  assertEquals(await authorize(gw, response(await idToken({}, 'nope'))), { status: 'challenge_invalid' });
  // first fetch only: cache is fresh, so no pointless refetch inside the 60 s window
  assertEquals(fx.calls.filter((c) => c.url.endsWith('/auth/keys')).length, 1);
  assertEquals((await authorize(gw, response(await idToken()))).status, 'ok');
  assertEquals(fx.calls.filter((c) => c.url.endsWith('/auth/keys')).length, 1);
  fx.now = NOW + 30 * 60_000; // inside TTL
  fx.challenge = { nonce_hash: NONCE_HASH, expires_at_ms: fx.now + 120_000, consumed: false };
  await authorize(gw, response(await idToken({ iat: Math.floor(fx.now / 1000), exp: Math.floor(fx.now / 1000) + 600 })));
  assertEquals(fx.calls.filter((c) => c.url.endsWith('/auth/keys')).length, 1);
  fx.now = NOW + 61 * 60_000; // past TTL
  fx.challenge = { nonce_hash: NONCE_HASH, expires_at_ms: fx.now + 120_000, consumed: false };
  await authorize(gw, response(await idToken({ iat: Math.floor(fx.now / 1000), exp: Math.floor(fx.now / 1000) + 600 })));
  assertEquals(fx.calls.filter((c) => c.url.endsWith('/auth/keys')).length, 2);
});

Deno.test('an unknown kid after the refetch window refreshes JWKS once and then verifies a rotated key', async () => {
  const { fx, gw } = fixture({ jwks: { keys: [ecJwk] } });
  assertEquals((await authorize(gw, response(await idToken()))).status, 'challenge_invalid');
  fx.now = NOW + 90_000;
  fx.jwks = { keys: [rsaJwk] };
  fx.challenge = { nonce_hash: NONCE_HASH, expires_at_ms: fx.now + 120_000, consumed: false };
  const t = await idToken({ iat: Math.floor(fx.now / 1000), exp: Math.floor(fx.now / 1000) + 600 });
  assertEquals((await authorize(gw, response(t))).status, 'ok');
});

Deno.test('a JWKS outage is an outage (throw), not a verdict', async () => {
  const { gw } = fixture({ jwksStatus: 503 });
  await assertRejects(async () => authorize(gw, response(await idToken())), Error, 'apple_jwks_unavailable');
});

// ── authorize: subject ───────────────────────────────────────────────────────
Deno.test('wrong, missing or empty stored subject is apple_subject_mismatch and never exchanges the code', async () => {
  for (const subject of ['someone-else', null, '', 42]) {
    const { fx, gw } = fixture({ subject });
    assertEquals(await authorize(gw, response(await idToken())), { status: 'apple_subject_mismatch' });
    assertFalse(fx.calls.some((c) => c.url.endsWith('/auth/token')));
  }
});

Deno.test('a failing subject lookup is an outage (throw)', async () => {
  const t = await idToken();
  const gw = createAppleDeletionGateway({
    fetch: (() => Promise.resolve(Response.json({ keys: [rsaJwk] }))) as typeof fetch,
    now: () => NOW,
    rpc: {
      rpc: (fn: string) =>
        Promise.resolve(
          fn === 'account_deletion_read_challenge'
            ? { data: { nonce_hash: NONCE_HASH, expires_at_ms: NOW + 1000, consumed: false }, error: null }
            : { data: null, error: { code: 'XX000' } },
        ),
    },
    config: { teamId: TEAM, keyId: KEY_ID, clientId: CLIENT_ID, privateKeyP8: P8_PEM },
  });
  await assertRejects(() => authorize(gw, response(t)));
});

// ── authorize: exchange ──────────────────────────────────────────────────────
Deno.test('exchange invalid_grant is challenge_invalid', async () => {
  const { gw } = fixture({ tokenResponse: () => Response.json({ error: 'invalid_grant' }, { status: 400 }) });
  assertEquals(await authorize(gw, response(await idToken())), { status: 'challenge_invalid' });
});

Deno.test('exchange 5xx, network error, other 4xx and malformed success are outages (throw)', async () => {
  const t = await idToken();
  const cases: Fx['tokenResponse'][] = [
    () => new Response('boom', { status: 503 }),
    () => new Response('boom', { status: 500 }),
    () => {
      throw new Error('network');
    },
    () => Response.json({ error: 'invalid_client' }, { status: 400 }),
    () => Response.json({ error: 'invalid_grant' }, { status: 401 }),
    () => Response.json({ access_token: 'only' }),
    () => new Response('not json', { status: 200 }),
  ];
  for (const tokenResponse of cases) {
    await assertRejects(() => authorize(fixture({ tokenResponse }).gw, response(t)));
  }
});

Deno.test('exchange id_token with a missing, malformed or different sub is apple_subject_mismatch and yields no refresh token', async () => {
  const t = await idToken();
  const bodies: unknown[] = [
    { refresh_token: 'r.x' },
    { refresh_token: 'r.x', id_token: 'not-a-jwt' },
    { refresh_token: 'r.x', id_token: 'a.!!!.c' },
    { refresh_token: 'r.x', id_token: unsignedJwt({}) },
    { refresh_token: 'r.x', id_token: unsignedJwt({ sub: 'someone.else' }) },
    { refresh_token: 'r.x', id_token: unsignedJwt({ sub: 42 }) },
    { refresh_token: 'r.x', id_token: 7 },
  ];
  for (const b of bodies) {
    const r = await authorize(fixture({ tokenResponse: () => Response.json(b) }).gw, response(t));
    assertEquals(r, { status: 'apple_subject_mismatch' });
  }
});

// ── revoke ───────────────────────────────────────────────────────────────────
Deno.test('revoke 200 is revoked_verified and posts the contract form fields', async () => {
  const { fx, gw } = fixture();
  assertEquals(await gw.revoke('the-refresh-token'), 'revoked_verified');
  const call = fx.calls.find((c) => c.url.endsWith('/auth/revoke'))!;
  const form = new URLSearchParams(call.body);
  assertEquals(form.get('token'), 'the-refresh-token');
  assertEquals(form.get('token_type_hint'), 'refresh_token');
  assertEquals(form.get('client_id'), CLIENT_ID);
  assertEquals(form.get('client_secret')!.split('.').length, 3);
});

Deno.test('revoke 400 invalid_grant is idempotently revoked_verified', async () => {
  const { gw } = fixture({ revokeResponse: () => Response.json({ error: 'invalid_grant' }, { status: 400 }) });
  assertEquals(await gw.revoke('t'), 'revoked_verified');
});

Deno.test('revoke 5xx and network errors are retryable', async () => {
  assertEquals(await fixture({ revokeResponse: () => new Response('x', { status: 500 }) }).gw.revoke('t'), 'retryable');
  assertEquals(await fixture({ revokeResponse: () => new Response('x', { status: 503 }) }).gw.revoke('t'), 'retryable');
  assertEquals(
    await fixture({ revokeResponse: () => {
      throw new Error('network');
    } }).gw.revoke('t'),
    'retryable',
  );
});

Deno.test('revoke 400 invalid_request and unsupported_token_type are permanent failures', async () => {
  for (const error of ['invalid_request', 'unsupported_token_type']) {
    assertEquals(await fixture({ revokeResponse: () => Response.json({ error }, { status: 400 }) }).gw.revoke('t'), 'failed');
  }
});

Deno.test('revoke config/auth errors, throttling and unparseable bodies are retryable, never failed', async () => {
  for (const error of ['invalid_client', 'unauthorized_client']) {
    assertEquals(await fixture({ revokeResponse: () => Response.json({ error }, { status: 400 }) }).gw.revoke('t'), 'retryable');
  }
  for (const status of [401, 403, 404, 429]) {
    assertEquals(await fixture({ revokeResponse: () => Response.json({ error: 'invalid_client' }, { status }) }).gw.revoke('t'), 'retryable');
  }
  assertEquals(await fixture({ revokeResponse: () => Response.json({ error: 'something_new' }, { status: 400 }) }).gw.revoke('t'), 'retryable');
  assertEquals(await fixture({ revokeResponse: () => new Response('', { status: 400 }) }).gw.revoke('t'), 'retryable');
  assertEquals(await fixture({ revokeResponse: () => new Response('<html>', { status: 400 }) }).gw.revoke('t'), 'retryable');
});

// ── timeouts ─────────────────────────────────────────────────────────────────
const timeoutError = () => new DOMException('The signal has timed out', 'TimeoutError');

Deno.test('every Apple fetch carries an abort signal', async () => {
  const { fx, gw } = fixture();
  assertEquals((await authorize(gw, response(await idToken()))).status, 'ok');
  assertEquals(await gw.revoke('t'), 'revoked_verified');
  assertEquals(fx.calls.length, 3);
  for (const c of fx.calls) assert(c.signal instanceof AbortSignal, c.url);
});

Deno.test('a timed-out JWKS fetch or code exchange is an outage (throw); a timed-out revoke is retryable', async () => {
  const t = await idToken();
  const gwJwks = createAppleDeletionGateway({
    fetch: (() => Promise.reject(timeoutError())) as typeof fetch,
    now: () => NOW,
    rpc: { rpc: (fn: string) => Promise.resolve({ data: fn === 'account_deletion_read_challenge' ? { nonce_hash: NONCE_HASH, expires_at_ms: NOW + 120_000, consumed: false } : SUB, error: null }) },
    config: { teamId: TEAM, keyId: KEY_ID, clientId: CLIENT_ID, privateKeyP8: P8_PEM },
  });
  await assertRejects(() => authorize(gwJwks, response(t)), Error, 'apple_jwks_unavailable');
  await assertRejects(
    () => authorize(fixture({ tokenResponse: () => Promise.reject(timeoutError()) }).gw, response(t)),
    Error,
    'apple_exchange_unavailable',
  );
  assertEquals(await fixture({ revokeResponse: () => Promise.reject(timeoutError()) }).gw.revoke('t'), 'retryable');
});

// ── config ───────────────────────────────────────────────────────────────────
Deno.test('parseAppleDeletionConfig requires every value to be present and well formed', () => {
  const env = (o: Record<string, string>) => (k: string) => o[k];
  const ok = { APPLE_TEAM_ID: TEAM, APPLE_KEY_ID: KEY_ID, APPLE_CLIENT_ID: CLIENT_ID, APPLE_PRIVATE_KEY_P8: P8_PEM };
  assert(parseAppleDeletionConfig(env(ok)) !== null);
  // literal \n sequences (common in env var pastes) are normalised
  assert(parseAppleDeletionConfig(env({ ...ok, APPLE_PRIVATE_KEY_P8: P8_PEM.replaceAll('\n', '\\n') })) !== null);
  for (const [k, v] of Object.entries({ APPLE_TEAM_ID: 'short', APPLE_KEY_ID: '', APPLE_CLIENT_ID: 'has space', APPLE_PRIVATE_KEY_P8: 'not a pem' })) {
    assertEquals(parseAppleDeletionConfig(env({ ...ok, [k]: v })), null, k);
  }
  for (const k of Object.keys(ok)) {
    const { [k]: _omit, ...rest } = ok as Record<string, string>;
    assertEquals(parseAppleDeletionConfig(env(rest)), null, k);
  }
});

Deno.test('a P8 that is well-formed PEM but not a P-256 key is reported unusable and fails closed on use', async () => {
  const junkPem = `-----BEGIN PRIVATE KEY-----\n${btoa('x'.repeat(48))}\n-----END PRIVATE KEY-----`;
  const gw = createAppleDeletionGateway({
    fetch: (() => Promise.reject(new Error('no network'))) as typeof fetch,
    now: () => NOW,
    rpc: { rpc: () => Promise.resolve({ data: null, error: null }) },
    config: { teamId: TEAM, keyId: KEY_ID, clientId: CLIENT_ID, privateKeyP8: junkPem },
  });
  assertEquals(await gw.signingKeyUsable(), false);
  assertEquals(await gw.revoke('t'), 'retryable');
});

Deno.test('no secret material appears in thrown error messages', async () => {
  const { gw } = fixture({ tokenResponse: () => new Response('refresh_token=leak-me', { status: 503 }) });
  const t = await idToken();
  const e = await assertRejects(() => authorize(gw, response(t, 'secret-code-xyz')));
  const msg = (e as Error).message;
  for (const s of ['secret-code-xyz', t, 'leak-me', 'PRIVATE KEY']) assertFalse(msg.includes(s));
});
