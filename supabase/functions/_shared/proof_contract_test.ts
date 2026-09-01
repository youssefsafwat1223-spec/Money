import { assert, assertEquals, assertNotEquals } from 'https://deno.land/std@0.208.0/testing/asserts.ts';
import { type GeminiRoute, resolveGeminiRoute } from './proof_contract.ts';

// Distinct sentinels. If routing ever crosses the wires, the assertion fails on
// the VALUE, not merely on a boolean — which is the whole point of this file.
// The previous version of this suite tested an accept/refuse gate that took a
// `shadowKeyPresent: boolean`. Every one of those tests passed while the
// function under test could not observe which credential was actually used, and
// the request was in fact funded by the production key. A boolean gate cannot
// catch a routing defect. These tests interrogate the returned credential.
const PROD = 'prod-key-sentinel';
const SHADOW = 'shadow-key-sentinel';
const BOTH = { productionKey: PROD, shadowKey: SHADOW };

function accepted(r: GeminiRoute) {
  assertEquals(r.refused, false);
  return r as Extract<GeminiRoute, { refused: false }>;
}
function refused(r: GeminiRoute) {
  assertEquals(r.refused, true);
  return r as Extract<GeminiRoute, { refused: true }>;
}

// ── 1. v1 selects the production credential ─────────────────────────────────

Deno.test('ROUTING: v1 selects the PRODUCTION credential', () => {
  const r = accepted(resolveGeminiRoute('v1', BOTH));
  assertEquals(r.source, 'production');
  assertEquals(r.key, PROD);
});

Deno.test('ROUTING: an ABSENT contract is v1 and selects production', () => {
  // The shipping v1 client has never sent the field. This is the case that
  // matters most for "existing v1 behaviour is unchanged".
  const r = accepted(resolveGeminiRoute(null, BOTH));
  assertEquals(r.source, 'production');
  assertEquals(r.key, PROD);
});

Deno.test('v1 is unaffected by the presence or absence of a shadow key', () => {
  for (const shadowKey of [SHADOW, '']) {
    for (const contract of [null, 'v1']) {
      const r = accepted(resolveGeminiRoute(contract, { productionKey: PROD, shadowKey }));
      assertEquals(r.source, 'production');
      assertEquals(r.key, PROD);
    }
  }
});

// ── 2. proof-v1 selects the shadow credential ───────────────────────────────

Deno.test('ROUTING: proof-v1 selects the SHADOW credential', () => {
  const r = accepted(resolveGeminiRoute('proof-v1', BOTH));
  assertEquals(r.source, 'shadow');
  assertEquals(r.key, SHADOW);
});

// ── 3. proof-v1 NEVER selects the production credential ─────────────────────

Deno.test('ISOLATION: proof-v1 never returns the production key, under any env', () => {
  // The defect this closes: proof-v1 accepted on the strength of the shadow key
  // existing, then served from GEMINI_API_KEY. Exhaustive over the credential
  // combinations a misconfiguration can produce.
  const envs = [
    { productionKey: PROD, shadowKey: SHADOW },
    { productionKey: PROD, shadowKey: '' },
    { productionKey: '', shadowKey: SHADOW },
    { productionKey: '', shadowKey: '' },
    { productionKey: PROD, shadowKey: PROD }, // even if both are set the same
  ];
  for (const env of envs) {
    const r = resolveGeminiRoute('proof-v1', env);
    if (r.refused) continue; // refusing is always a safe outcome
    assertEquals(r.source, 'shadow');
    assertEquals(r.key, env.shadowKey);
    assertNotEquals(r.source as string, 'production');
  }
});

Deno.test('ISOLATION: proof-v1 refuses rather than borrowing production capacity', () => {
  // A production key IS configured here. The old code would have served the
  // request from it; the only safe answer is refusal.
  const r = refused(resolveGeminiRoute('proof-v1', { productionKey: PROD, shadowKey: '' }));
  assertEquals(r.code, 'upstream_unavailable');
  assertEquals(r.retryable, false);
});

// ── 4. missing shadow credential refuses BEFORE any model call ──────────────

Deno.test('INERT DEPLOYMENT: no shadow credential means no route, so no call is possible', () => {
  // The refusal carries no credential at all, so the caller has nothing to make
  // a request with even if it ignored `refused`. That is what "refuses before
  // the model call" means structurally, rather than by call ordering.
  const r = resolveGeminiRoute('proof-v1', { productionKey: PROD, shadowKey: '' });
  assert(r.refused);
  assert(!('key' in r), 'a refusal must not carry a credential');
  assert(!('source' in r), 'a refusal must not name a credential source');
});

// ── 5. unknown contract is refused ──────────────────────────────────────────

Deno.test('an unknown contract is refused, not guessed', () => {
  for (const c of ['proof-v2', 'v2', 'PROOF-V1', 'proof-v1 ', '', 'null']) {
    const r = refused(resolveGeminiRoute(c, BOTH));
    assertEquals(r.code, 'unsupported_schema', `contract ${JSON.stringify(c)}`);
    assertEquals(r.retryable, false);
  }
});

Deno.test('an unknown contract is refused even when both credentials exist', () => {
  // Refusal must not depend on a credential being missing — a future contract
  // has to be implemented, never served by whichever branch is closest.
  const r = refused(resolveGeminiRoute('proof-v2', BOTH));
  assertEquals(r.code, 'unsupported_schema');
});

// ── 6. no refusal output can expose either credential ───────────────────────

Deno.test('PRIVACY: no refusal payload contains either key, serialized or not', () => {
  const refusals = [
    resolveGeminiRoute('proof-v1', { productionKey: PROD, shadowKey: '' }),
    resolveGeminiRoute('proof-v2', BOTH),
    resolveGeminiRoute('', BOTH),
  ];
  for (const r of refusals) {
    const serialized = JSON.stringify(r);
    assertEquals(serialized.includes(PROD), false, serialized);
    assertEquals(serialized.includes(SHADOW), false, serialized);
    // Also covers a caller that logs the object rather than the JSON.
    assertEquals(Object.values(r as Record<string, unknown>).includes(PROD), false);
    assertEquals(Object.values(r as Record<string, unknown>).includes(SHADOW), false);
  }
});

Deno.test('PRIVACY: the refusal code is the only thing safe to log, and it is opaque', () => {
  // Regression guard for a tempting "helpful" error: the code must never name
  // the variable, the project or the fact that a DIFFERENT key would have
  // worked — that tells a prober how the arms are configured.
  const r = refused(resolveGeminiRoute('proof-v1', { productionKey: PROD, shadowKey: '' }));
  for (const leak of ['GEMINI', 'shadow', 'key', 'credential', 'production']) {
    assertEquals(r.code.toLowerCase().includes(leak.toLowerCase()), false, leak);
  }
});
