// COUPONS Phase 3 — attribution.
//
// Everything here defends one of two properties:
//
//   1. A click cannot be traced to a person. The server holds no user, device,
//      IP or user-agent, and the sub-id it hands the network is a bare random
//      id. If any test here starts passing because we added an identifier "just
//      for debugging", the design is gone.
//
//   2. A wrong token learns NOTHING. Not whether the click exists, not whether
//      it expired, not how close the guess was. Otherwise this endpoint becomes
//      an oracle for enumerating other people's clicks.

import { assert, assertEquals, assertRejects } from 'https://deno.land/std@0.208.0/testing/asserts.ts';
import {
  type ConversionEvent,
  prepareClick,
  publicStatusFor,
  sha256Hex,
  shouldApplyTransition,
  timingSafeEqualHex,
  validateConversion,
} from './attribution.ts';

const FUTURE = new Date(Date.now() + 86_400_000).toISOString();
const PAST = new Date(Date.now() - 86_400_000).toISOString();

Deno.test('the sub-id handed to the network is the click id and NOTHING else', async () => {
  // Networks accept arbitrary sub-ids, and packing a user or install reference
  // in is the convenient thing to do. It would also hand a commercial partner a
  // stable identifier for a person.
  const prepared = await prepareClick('https://partner.test/offer?a=1', 'subid');
  const url = new URL(prepared.trackingUrl);
  assertEquals(url.searchParams.get('subid'), prepared.clickId);
  // The original query survives; we add, never rewrite.
  assertEquals(url.searchParams.get('a'), '1');
  // And nothing else was appended.
  assertEquals([...url.searchParams.keys()].sort(), ['a', 'subid']);
});

Deno.test('the server stores a hash, never the token', async () => {
  const prepared = await prepareClick('https://partner.test/x', 'subid');
  assertEquals(prepared.claimSecretHash, await sha256Hex(prepared.claimToken));
  assert(prepared.claimSecretHash !== prepared.claimToken);
  assert(/^[0-9a-f]{64}$/.test(prepared.claimSecretHash));
});

Deno.test('the claim token is random, not derived', async () => {
  // Deriving it from the click id or a timestamp would make it guessable from
  // data the network already holds, and only the device is supposed to have it.
  const a = await prepareClick('https://partner.test/x', 'subid');
  const b = await prepareClick('https://partner.test/x', 'subid');
  assert(a.claimToken !== b.claimToken);
  assert(a.clickId !== b.clickId);
  assert(!a.claimToken.includes(a.clickId.replace(/-/g, '')));
});

Deno.test('an insecure destination is refused outright', async () => {
  // A tracked click that downgrades the connection gives the user neither
  // privacy nor the offer safely.
  await assertRejects(() => prepareClick('http://partner.test/x', 'subid'));
});

Deno.test('a wrong token is indistinguishable from a missing click', async () => {
  const hash = await sha256Hex('the-real-token');
  const row = { claim_secret_hash: hash, expires_at: FUTURE };

  const wrong = await sha256Hex('a-guess');
  assertEquals(publicStatusFor(row, wrong, 'approved'), 'unknown');
  assertEquals(publicStatusFor(null, hash, 'approved'), 'unknown');
  assertEquals(publicStatusFor(row, 'not-a-hash', 'approved'), 'unknown');
  // An expired click also reports `unknown`, so the three cases cannot be told
  // apart by a caller probing ids.
  assertEquals(
    publicStatusFor({ claim_secret_hash: hash, expires_at: PAST }, hash, 'approved'),
    'unknown',
  );
});

Deno.test('a verified token maps provider status to the device vocabulary', async () => {
  const hash = await sha256Hex('t');
  const row = { claim_secret_hash: hash, expires_at: FUTURE };
  assertEquals(publicStatusFor(row, hash, 'approved'), 'confirmed');
  assertEquals(publicStatusFor(row, hash, 'pending'), 'pending');
  for (const declined of ['rejected', 'returned', 'cancelled']) {
    assertEquals(publicStatusFor(row, hash, declined), 'declined');
  }
});

Deno.test('a verified click with no conversion yet is pending, not unknown', async () => {
  // The device legitimately holds this click and is entitled to know the
  // network simply has not reported. Saying `unknown` would make a working
  // system look broken.
  const hash = await sha256Hex('t');
  assertEquals(
    publicStatusFor({ claim_secret_hash: hash, expires_at: FUTURE }, hash, null),
    'pending',
  );
});

Deno.test('hash comparison does not short-circuit', () => {
  // A compare that returns early on the first mismatched character leaks how
  // many leading characters were right, and a token becomes brute-forceable one
  // nibble at a time.
  const a = 'a'.repeat(64);
  assert(timingSafeEqualHex(a, a));
  assert(!timingSafeEqualHex(a, 'b' + 'a'.repeat(63)));
  assert(!timingSafeEqualHex(a, 'a'.repeat(63) + 'b'));
  assert(!timingSafeEqualHex(a, 'a'.repeat(63)));
  assert(!timingSafeEqualHex(a, ''));
});

// ── the conversion state machine ───────────────────────────────────────────

function event(over: Partial<ConversionEvent> = {}): ConversionEvent {
  return { externalConversionId: 'c-1', clickId: null, status: 'pending', ...over };
}

Deno.test('an amount without its currency is rejected', () => {
  // The same trap the 0097 CHECK fell into: `amount IS NULL OR currency ~ ...`
  // passes when the currency is NULL, because the regex evaluates to NULL and a
  // CHECK only rejects FALSE.
  for (const over of [
    { commissionAmountMinor: 500 },
    { orderAmountMinor: 500 },
    { providerDiscountMinor: 500 },
  ]) {
    assert(validateConversion(event(over)).includes('amount_without_currency'),
      JSON.stringify(over));
  }
});

Deno.test('a conversion with no correlatable click is still VALID', () => {
  // Networks report conversions we cannot correlate — a lost sub-id, a click
  // from a build predating tracking. Dropping them understates revenue;
  // attaching them to a guess would be worse.
  assertEquals(validateConversion(event({ clickId: null })), []);
});

Deno.test('a malformed click id is rejected rather than stored', () => {
  assert(validateConversion(event({ clickId: 'not-a-uuid' })).includes('bad_click_id'));
});

Deno.test('a negative amount is rejected', () => {
  assert(validateConversion(event({
    commissionAmountMinor: -1, commissionCurrency: 'SAR',
  })).includes('negative_amount'));
});

Deno.test('a clawback is STICKY against a late approval', () => {
  // Networks deliver out of order, especially when an outage replays a backlog.
  // Applying by arrival would leave a returned conversion sitting at approved —
  // counting revenue that was taken back.
  assertEquals(shouldApplyTransition('returned', 'approved'), false);
  assertEquals(shouldApplyTransition('rejected', 'approved'), false);
  assertEquals(shouldApplyTransition('cancelled', 'pending'), false);
});

Deno.test('a clawback always applies, whatever the current state', () => {
  // The reverse direction is news and must never be suppressed.
  assertEquals(shouldApplyTransition('approved', 'returned'), true);
  assertEquals(shouldApplyTransition('pending', 'rejected'), true);
  assertEquals(shouldApplyTransition('approved', 'cancelled'), true);
});

Deno.test('a repeated status is a no-op', () => {
  // A network resending the same event must not append a history entry saying
  // something changed when nothing did.
  assertEquals(shouldApplyTransition('approved', 'approved'), false);
});

Deno.test('a normal progression applies', () => {
  assertEquals(shouldApplyTransition('pending', 'approved'), true);
});
