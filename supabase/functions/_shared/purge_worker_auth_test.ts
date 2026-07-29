import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { bearerSecretAuthorized } from './capture_auth.ts';

// End-to-end proof of the account-purge worker's authorization decision
// (MALI-005). Uses a throwaway fixture secret — no real secret value appears
// here or in logs. Mirrors exactly what the Edge Function evaluates:
//   bearerSecretAuthorized(req.authorization, Deno.env.PURGE_WORKER_SECRET)

const kSecret = 'fixture-worker-secret-not-real';

Deno.test('configured secret with matching Bearer token is authorized', () => {
  assertEquals(bearerSecretAuthorized(`Bearer ${kSecret}`, kSecret), true);
});

Deno.test('a wrong token is rejected', () => {
  assertEquals(bearerSecretAuthorized('Bearer totally-wrong', kSecret), false);
});

Deno.test('a token that is a prefix/suffix of the secret is rejected', () => {
  assertEquals(bearerSecretAuthorized(`Bearer ${kSecret.slice(0, -4)}`, kSecret), false);
  assertEquals(bearerSecretAuthorized(`Bearer ${kSecret}x`, kSecret), false);
});

Deno.test('missing Authorization header is rejected', () => {
  assertEquals(bearerSecretAuthorized(null, kSecret), false);
  assertEquals(bearerSecretAuthorized(undefined, kSecret), false);
  assertEquals(bearerSecretAuthorized('', kSecret), false);
});

Deno.test('non-Bearer scheme is rejected', () => {
  assertEquals(bearerSecretAuthorized(kSecret, kSecret), false); // no "Bearer " prefix
  assertEquals(bearerSecretAuthorized(`Basic ${kSecret}`, kSecret), false);
});

Deno.test('empty/unconfigured secret never authorizes (fail closed)', () => {
  // A misconfigured environment (secret unset) must reject everything,
  // including an empty presented token.
  assertEquals(bearerSecretAuthorized('Bearer ', ''), false);
  assertEquals(bearerSecretAuthorized('Bearer anything', ''), false);
  assertEquals(bearerSecretAuthorized(null, ''), false);
});
