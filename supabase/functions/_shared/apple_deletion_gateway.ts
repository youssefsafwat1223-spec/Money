// Real AppleGateway for immediate account deletion (contract sections 4 and 5).
//
// Everything is injected (fetch, clock, RPC client, config) so tests are offline.
// Tokens, codes, client secrets and keys are never logged and never placed in
// thrown error messages. Outages throw fixed strings; the coordinator maps a
// throw to authorization_unavailable (retryable).

import type { AppleAuthorizeResult, AppleGateway, RpcClient } from './account_deletion_adapter.ts';
import { b64urlDecode, b64urlEncode } from './material_sealer.ts';

const APPLE_ISSUER = 'https://appleid.apple.com';
const JWKS_URL = 'https://appleid.apple.com/auth/keys';
const TOKEN_URL = 'https://appleid.apple.com/auth/token';
const REVOKE_URL = 'https://appleid.apple.com/auth/revoke';

export const JWKS_TTL_MS = 60 * 60 * 1000;
const JWKS_MIN_REFETCH_MS = 60 * 1000;
const SKEW_MS = 60 * 1000;
// Bound every Apple call so a hung connection lands in the outage/retryable branches.
const FETCH_TIMEOUT_MS = 10_000;
const CLIENT_SECRET_LIFETIME_S = 5 * 60;

export interface AppleDeletionConfig {
  teamId: string;
  keyId: string;
  clientId: string;
  privateKeyP8: string;
}

export interface AppleGatewayDeps {
  fetch: typeof fetch;
  now: () => number;
  rpc: RpcClient;
  config: AppleDeletionConfig;
}

/** Returns a config only when all four values are present and well-formed, else null. */
export function parseAppleDeletionConfig(get: (name: string) => string | undefined): AppleDeletionConfig | null {
  const teamId = (get('APPLE_TEAM_ID') ?? '').trim();
  const keyId = (get('APPLE_KEY_ID') ?? '').trim();
  const clientId = (get('APPLE_CLIENT_ID') ?? '').trim();
  const pem = normalizePem(get('APPLE_PRIVATE_KEY_P8') ?? '');
  if (!/^[A-Z0-9]{10}$/.test(teamId) || !/^[A-Z0-9]{10}$/.test(keyId)) return null;
  if (!/^[A-Za-z0-9][A-Za-z0-9.-]{1,254}$/.test(clientId)) return null;
  if (pemBody(pem) === null) return null;
  return { teamId, keyId, clientId, privateKeyP8: pem };
}

// Secrets pasted into env vars often carry literal "\n" sequences.
function normalizePem(raw: string): string {
  return raw.trim().replaceAll('\\n', '\n');
}

function pemBody(pem: string): Uint8Array | null {
  const m = /^-----BEGIN PRIVATE KEY-----([A-Za-z0-9+/=\s]+)-----END PRIVATE KEY-----$/.exec(pem.trim());
  if (!m) return null;
  const b64 = m[1].replace(/\s+/g, '');
  if (b64.length === 0 || b64.length % 4 !== 0) return null;
  try {
    const bin = atob(b64);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  } catch {
    return null;
  }
}

const enc = new TextEncoder();
const isObject = (v: unknown): v is Record<string, unknown> => typeof v === 'object' && v !== null && !Array.isArray(v);

function constantTimeEqual(a: string, b: string): boolean {
  const x = enc.encode(a);
  const y = enc.encode(b);
  let diff = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}

function parseJson(bytes: Uint8Array): unknown {
  return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
}

class TokenInvalid extends Error {}

type Challenge = { nonceHash: string; expiresAtMs: number; consumed: boolean };

export function createAppleDeletionGateway(deps: AppleGatewayDeps): AppleGateway & {
  /** Imports the P8 key once; true when the signing key is usable. */
  signingKeyUsable(): Promise<boolean>;
} {
  const { config } = deps;
  let signingKey: Promise<CryptoKey> | null = null;
  let jwks: { keys: JsonWebKey[]; fetchedAt: number } | null = null;

  function getSigningKey(): Promise<CryptoKey> {
    if (!signingKey) {
      const der = pemBody(config.privateKeyP8);
      if (!der) return Promise.reject(new Error('apple_key_invalid'));
      signingKey = crypto.subtle.importKey('pkcs8', der as BufferSource, { name: 'ECDSA', namedCurve: 'P-256' }, false, [
        'sign',
      ]).catch(() => {
        signingKey = null;
        throw new Error('apple_key_invalid');
      });
    }
    return signingKey;
  }

  async function clientSecret(): Promise<string> {
    const key = await getSigningKey();
    const iat = Math.floor(deps.now() / 1000);
    const header = b64urlEncode(enc.encode(JSON.stringify({ alg: 'ES256', kid: config.keyId, typ: 'JWT' })));
    const payload = b64urlEncode(enc.encode(JSON.stringify({
      iss: config.teamId,
      iat,
      exp: iat + CLIENT_SECRET_LIFETIME_S,
      aud: APPLE_ISSUER,
      sub: config.clientId,
    })));
    const input = `${header}.${payload}`;
    const sig = new Uint8Array(await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, enc.encode(input)));
    return `${input}.${b64urlEncode(sig)}`;
  }

  async function loadJwks(force: boolean): Promise<JsonWebKey[]> {
    const now = deps.now();
    if (jwks && now - jwks.fetchedAt < JWKS_TTL_MS && !force) return jwks.keys;
    let res: Response;
    try {
      res = await deps.fetch(JWKS_URL, {
        method: 'GET',
        headers: { accept: 'application/json' },
        signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
      });
    } catch {
      throw new Error('apple_jwks_unavailable');
    }
    if (!res.ok) {
      await res.body?.cancel().catch(() => {});
      throw new Error('apple_jwks_unavailable');
    }
    let body: unknown;
    try {
      body = await res.json();
    } catch {
      throw new Error('apple_jwks_unavailable');
    }
    if (!isObject(body) || !Array.isArray(body.keys)) throw new Error('apple_jwks_unavailable');
    const keys = body.keys.filter(isObject) as JsonWebKey[];
    jwks = { keys, fetchedAt: now };
    return keys;
  }

  async function findJwk(kid: string): Promise<JsonWebKey | null> {
    let keys = await loadJwks(false);
    let hit = keys.find((k) => (k as { kid?: string }).kid === kid);
    // Apple rotates keys: one bounded refresh on an unknown kid.
    if (!hit && jwks && deps.now() - jwks.fetchedAt >= JWKS_MIN_REFETCH_MS) {
      keys = await loadJwks(true);
      hit = keys.find((k) => (k as { kid?: string }).kid === kid);
    }
    return hit ?? null;
  }

  /** Returns the verified claims, or throws TokenInvalid. Infrastructure failures throw other errors. */
  async function verifyIdentityToken(token: string, nonceHash: string): Promise<{ sub: string }> {
    const parts = token.split('.');
    if (parts.length !== 3) throw new TokenInvalid();
    let header: unknown;
    let claims: unknown;
    let sig: Uint8Array;
    try {
      header = parseJson(b64urlDecode(parts[0]));
      claims = parseJson(b64urlDecode(parts[1]));
      sig = b64urlDecode(parts[2]);
    } catch {
      throw new TokenInvalid();
    }
    if (!isObject(header) || !isObject(claims)) throw new TokenInvalid();
    if ((header.alg !== 'RS256' && header.alg !== 'ES256') || typeof header.kid !== 'string') throw new TokenInvalid();

    const jwk = await findJwk(header.kid);
    if (!jwk) throw new TokenInvalid();
    const rsa = header.alg === 'RS256';
    if (jwk.kty !== (rsa ? 'RSA' : 'EC')) throw new TokenInvalid();
    if (jwk.alg !== undefined && jwk.alg !== header.alg) throw new TokenInvalid();
    if (jwk.use !== undefined && jwk.use !== 'sig') throw new TokenInvalid();

    let ok = false;
    try {
      const key = await crypto.subtle.importKey(
        'jwk',
        { kty: jwk.kty, n: jwk.n, e: jwk.e, crv: jwk.crv, x: jwk.x, y: jwk.y, ext: true },
        rsa ? { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' } : { name: 'ECDSA', namedCurve: 'P-256' },
        false,
        ['verify'],
      );
      ok = await crypto.subtle.verify(
        rsa ? { name: 'RSASSA-PKCS1-v1_5' } : { name: 'ECDSA', hash: 'SHA-256' },
        key,
        sig as BufferSource,
        enc.encode(`${parts[0]}.${parts[1]}`),
      );
    } catch {
      throw new TokenInvalid();
    }
    if (!ok) throw new TokenInvalid();

    if (claims.iss !== APPLE_ISSUER) throw new TokenInvalid();
    const aud = claims.aud;
    if (!(aud === config.clientId || (Array.isArray(aud) && aud.length === 1 && aud[0] === config.clientId))) {
      throw new TokenInvalid();
    }
    if (typeof claims.exp !== 'number' || !Number.isFinite(claims.exp)) throw new TokenInvalid();
    if (claims.exp * 1000 + SKEW_MS <= deps.now()) throw new TokenInvalid();
    if (typeof claims.iat === 'number' && claims.iat * 1000 - SKEW_MS > deps.now()) throw new TokenInvalid();
    if (typeof claims.nonce !== 'string' || !constantTimeEqual(claims.nonce, nonceHash)) throw new TokenInvalid();
    if (typeof claims.sub !== 'string' || claims.sub.length === 0) throw new TokenInvalid();
    return { sub: claims.sub };
  }

  async function rpcData(fn: string, args: Record<string, unknown>): Promise<unknown> {
    const res = await deps.rpc.rpc(fn, args);
    if (!isObject(res) || res.error) throw new Error('apple_rpc_failed');
    const data = res.data;
    return Array.isArray(data) ? (data.length === 0 ? null : data[0]) : data;
  }

  async function readChallenge(uid: string, challengeId: string): Promise<Challenge | null> {
    const d = await rpcData('account_deletion_read_challenge', { p_uid: uid, p_challenge_id: challengeId });
    if (d === null || d === undefined) return null;
    if (
      !isObject(d) || typeof d.nonce_hash !== 'string' || typeof d.expires_at_ms !== 'number' ||
      !Number.isFinite(d.expires_at_ms) || typeof d.consumed !== 'boolean'
    ) throw new Error('apple_challenge_malformed');
    return { nonceHash: d.nonce_hash, expiresAtMs: d.expires_at_ms, consumed: d.consumed };
  }

  async function appleSubject(uid: string): Promise<string | null> {
    const d = await rpcData('account_deletion_apple_subject', { p_uid: uid });
    return typeof d === 'string' && d.length > 0 ? d : null;
  }

  async function postForm(url: string, form: Record<string, string>): Promise<Response> {
    return await deps.fetch(url, {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded', accept: 'application/json' },
      body: new URLSearchParams(form).toString(),
      signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
    });
  }

  function exchangeSubjectMatches(idToken: unknown, expected: string): boolean {
    if (typeof idToken !== 'string') return false;
    const parts = idToken.split('.');
    if (parts.length !== 3) return false;
    try {
      const claims = parseJson(b64urlDecode(parts[1]));
      return isObject(claims) && typeof claims.sub === 'string' && constantTimeEqual(claims.sub, expected);
    } catch {
      return false;
    }
  }

  async function errorCodeOf(res: Response): Promise<string | null> {
    try {
      const b = await res.json();
      return isObject(b) && typeof b.error === 'string' ? b.error : null;
    } catch {
      return null;
    }
  }

  return {
    signingKeyUsable: () => getSigningKey().then(() => true, () => false),

    async authorize(input): Promise<AppleAuthorizeResult> {
      let identityToken: string;
      let authorizationCode: string;
      try {
        const parsed: unknown = JSON.parse(input.challengeResponse);
        if (
          !isObject(parsed) || typeof parsed.identity_token !== 'string' || parsed.identity_token.length === 0 ||
          typeof parsed.authorization_code !== 'string' || parsed.authorization_code.length === 0
        ) return { status: 'challenge_invalid' };
        identityToken = parsed.identity_token;
        authorizationCode = parsed.authorization_code;
      } catch {
        return { status: 'challenge_invalid' };
      }

      const challenge = await readChallenge(input.uid, input.challengeId);
      if (!challenge) return { status: 'challenge_invalid' };
      if (challenge.consumed) return { status: 'challenge_replayed' };
      if (challenge.expiresAtMs <= deps.now()) return { status: 'challenge_expired' };

      let sub: string;
      try {
        sub = (await verifyIdentityToken(identityToken, challenge.nonceHash)).sub;
      } catch (e) {
        if (e instanceof TokenInvalid) return { status: 'challenge_invalid' };
        throw e;
      }

      const stored = await appleSubject(input.uid);
      if (stored === null || !constantTimeEqual(stored, sub)) return { status: 'apple_subject_mismatch' };

      let res: Response;
      try {
        res = await postForm(TOKEN_URL, {
          grant_type: 'authorization_code',
          code: authorizationCode,
          client_id: config.clientId,
          client_secret: await clientSecret(),
        });
      } catch {
        throw new Error('apple_exchange_unavailable');
      }
      if (res.status === 400 && (await errorCodeOf(res)) === 'invalid_grant') return { status: 'challenge_invalid' };
      if (!res.ok) {
        await res.body?.cancel().catch(() => {});
        throw new Error('apple_exchange_unavailable');
      }
      let body: unknown;
      try {
        body = await res.json();
      } catch {
        throw new Error('apple_exchange_malformed');
      }
      if (!isObject(body) || typeof body.refresh_token !== 'string' || body.refresh_token.length === 0) {
        throw new Error('apple_exchange_malformed');
      }
      // Cross-check: the id_token Apple returns for this exchange must name the
      // same subject. It arrived over TLS in direct answer to our authenticated
      // request, so only the claim is read here, not a second signature.
      if (!exchangeSubjectMatches(body.id_token, sub)) {
        // The exchange minted a live refresh token for a different subject; revoke
        // it best-effort so it is not left behind. Nothing here may alter the verdict.
        try {
          const rv = await postForm(REVOKE_URL, {
            token: body.refresh_token,
            token_type_hint: 'refresh_token',
            client_id: config.clientId,
            client_secret: await clientSecret(),
          });
          await rv.body?.cancel().catch(() => {});
        } catch { /* best effort */ }
        return { status: 'apple_subject_mismatch' };
      }
      return { status: 'ok', refreshToken: body.refresh_token, challengeExpiresAtMs: challenge.expiresAtMs };
    },

    async revoke(refreshToken): Promise<'revoked_verified' | 'retryable' | 'failed'> {
      let res: Response;
      try {
        res = await postForm(REVOKE_URL, {
          token: refreshToken,
          token_type_hint: 'refresh_token',
          client_id: config.clientId,
          client_secret: await clientSecret(),
        });
      } catch {
        return 'retryable';
      }
      if (res.status === 200) {
        await res.body?.cancel().catch(() => {});
        return 'revoked_verified';
      }
      // Only a clearly permanent token/request error is terminal. Everything else
      // (client config, key rotation, clock skew, throttling, outages, unparseable
      // bodies) is retryable so an operator fix does not strand in-flight deletions.
      const code = res.status === 400 ? await errorCodeOf(res) : null;
      if (res.status === 400 && code === 'invalid_grant') return 'revoked_verified';
      await res.body?.cancel().catch(() => {});
      if (res.status === 400 && (code === 'invalid_request' || code === 'unsupported_token_type')) return 'failed';
      return 'retryable';
    },
  };
}
