// Auth contract for evaluate-gamification (migration 0099).
//
// Before 0099 this compared the caller's bearer against the PLATFORM-RESERVED
// SUPABASE_SERVICE_ROLE_KEY, whose value Supabase rotates and which differs
// from the project's real service-role JWT — so no caller, including the
// dispatcher, could present it and the endpoint was unreachable in production.
//
// One handler per test file on purpose: importing the module starts its
// `serve()` listener, so two in one file collide on the same port.

import { assertEquals } from 'https://deno.land/std@0.208.0/testing/asserts.ts';

const OWN = 'engagement-secret';
const OTHER = 'reminders-secret';
const PLATFORM = 'platform-reserved-value';
const OWN_ENV = 'ENGAGEMENT_WORKER_SECRET';

Deno.env.set('ENGAGEMENT_WORKER_SECRET', OWN);
Deno.env.set('REMINDERS_WORKER_SECRET', OTHER);
Deno.env.set('SUPABASE_URL', 'https://example.supabase.co');
Deno.env.set('SUPABASE_SERVICE_ROLE_KEY', PLATFORM);

const { handleEvaluateGamification } = await import('./index.ts');

function req(auth?: string): Request {
  const headers: Record<string, string> = { 'content-type': 'application/json' };
  if (auth !== undefined) headers.authorization = auth;
  return new Request('https://x/fn', { method: 'POST', headers, body: '{}' });
}

Deno.test('evaluate-gamification: no auth header is rejected', async () => {
  assertEquals((await handleEvaluateGamification(req())).status, 403);
});

Deno.test('evaluate-gamification: a wrong secret is rejected', async () => {
  assertEquals((await handleEvaluateGamification(req('Bearer not-the-secret'))).status, 403);
});

Deno.test('evaluate-gamification: an empty bearer is rejected', async () => {
  assertEquals((await handleEvaluateGamification(req('Bearer '))).status, 403);
});

Deno.test('evaluate-gamification: the token without the Bearer prefix is rejected', async () => {
  assertEquals((await handleEvaluateGamification(req(OWN))).status, 403);
});

Deno.test('evaluate-gamification: the platform SUPABASE_SERVICE_ROLE_KEY is NOT accepted', async () => {
  // The exact credential the deprecated contract expected. Accepting it would
  // mean the old path is still live.
  assertEquals((await handleEvaluateGamification(req(`Bearer ${PLATFORM}`))).status, 403);
});

Deno.test('evaluate-gamification: the OTHER domain\'s worker secret is rejected', async () => {
  // Least-privilege boundary: the engagement trio and the retired reminders
  // endpoint must not unlock each other.
  assertEquals((await handleEvaluateGamification(req(`Bearer ${OTHER}`))).status, 403);
});

Deno.test('evaluate-gamification: the correct dedicated secret is ACCEPTED', async () => {
  // Non-vacuity: without this every assertion above would also pass against a
  // handler hard-wired to reject everything.
  const res = await handleEvaluateGamification(req(`Bearer ${OWN}`));
  assertEquals(res.status !== 403, true, `expected not-403, got ${res.status}`);
});

Deno.test('evaluate-gamification: an UNSET secret rejects even an empty bearer', async () => {
  // The fail-closed guard, which every other test leaves unexercised because
  // they all run with a secret configured. Without `!workerSecret ||`, an
  // unconfigured deployment compares '' against '' — which is EQUAL — and the
  // endpoint would authenticate anyone sending `Authorization: Bearer `.
  const saved = Deno.env.get(OWN_ENV)!;
  Deno.env.delete(OWN_ENV);
  try {
    assertEquals((await handleEvaluateGamification(req('Bearer '))).status, 403);
    assertEquals((await handleEvaluateGamification(req('Bearer ' + saved))).status, 403);
    assertEquals((await handleEvaluateGamification(req())).status, 403);
  } finally {
    Deno.env.set(OWN_ENV, saved);
  }
});
