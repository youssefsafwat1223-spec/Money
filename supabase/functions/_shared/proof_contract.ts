// PHASE 7 — the AUTHORITATIVE contract → credential routing.
//
// This module is imported by parse-sms/index.ts. It is deliberately not a
// mirror of the logic there: an earlier version of this file duplicated only
// the accept/refuse decision, which is exactly why a defect survived a green
// test suite. The gate was correct and separately tested, while the request was
// still funded by the production key, because "which credential" was never part
// of what the shared module decided. Routing and refusal now live in one
// function, and the function that returns the credential is the same one the
// tests interrogate.
//
// The rule this exists to enforce: the shadow arm must NEVER consume the
// capacity the production path needs. There is no fallback from shadow to
// production, in either direction, under any input.

export type GeminiSource = 'production' | 'shadow';

/// A subset of the endpoint's `ApiErrorCode`, narrow enough to pass straight to
/// `apiError` without a cast and without this module importing the endpoint.
export type RouteRefusalCode = 'upstream_unavailable' | 'unsupported_schema';

export type GeminiRoute =
  | { refused: true; code: RouteRefusalCode; retryable: boolean }
  | { refused: false; source: GeminiSource; key: string };

/** The credentials available to the function, read from the environment. */
export type GeminiEnv = { productionKey: string; shadowKey: string };

/**
 * Decide which Gemini credential — if any — serves a request.
 *
 * `contract` is the caller-supplied marker. Absent (`null`) is the shipping v1
 * client, which has never sent the field; `'v1'` is accepted as the explicit
 * spelling of the same thing. Both route to production, so existing v1 traffic
 * is unaffected.
 *
 * NOTE ON THE EMPTY PRODUCTION KEY: a production route with no production key
 * configured is returned as ACCEPTED with an empty `key`, not as a refusal. That
 * is deliberate. The caller already refuses on a missing production key at a
 * specific point in the request, after re-sanitization and evidence-span
 * validation, and moving that decision earlier would change which error a
 * malformed v1 request receives. Preserving v1 byte-for-byte matters more than
 * the tidier shape. The shadow branch has no such constraint: it refuses here,
 * before anything else happens, because there is no pre-existing ordering to
 * keep and the earliest possible refusal is the safest one.
 */
export function resolveGeminiRoute(
  contract: string | null,
  env: GeminiEnv,
): GeminiRoute {
  // v1 — absent or explicit. Byte-identical handling to before this module.
  if (contract === null || contract === undefined || contract === 'v1') {
    return { refused: false, source: 'production', key: env.productionKey };
  }

  // proof-v1 — the shadow arm, served ONLY from the dedicated credential.
  if (contract === 'proof-v1') {
    if (!env.shadowKey) {
      // Not retryable: retrying cannot conjure a credential, and a retry storm
      // against a deliberately unprovisioned arm is pure noise.
      return { refused: true, code: 'upstream_unavailable', retryable: false };
    }
    return { refused: false, source: 'shadow', key: env.shadowKey };
  }

  // Anything else is refused, never guessed. A future 'proof-v2' must be
  // implemented, not silently served by whichever branch happens to be closest.
  return { refused: true, code: 'unsupported_schema', retryable: false };
}
