// COUPONS Phase 2 — turning a staged provider offer into a coupon.
//
// The theme: this function INVENTS NOTHING. Every place a provider left a gap,
// the reviewer is made to decide rather than handed a default that is right
// often enough to stop being questioned and wrong often enough to matter.

import assert from 'node:assert/strict';
import test from 'node:test';

import { buildCouponFromSource, couponSlugFor } from '../lib/affiliate-publish.mjs';

const OK = { merchantId: 'm-1', displayCategoryKey: 'shopping' };
const codes = (r) => r.fields.map((f) => `${f.field}:${f.code}`);

function normalized(over = {}) {
  return {
    externalOfferId: 'o-1',
    externalProgramId: 'p-1',
    titleAr: 'عنوان',
    descriptionAr: 'وصف',
    redemptionType: 'link',
    url: 'https://example.test/x',
    markets: ['SA'],
    ...over,
  };
}

test('a published affiliate coupon starts INACTIVE and UNVERIFIED', () => {
  // Inactive: the reviewer publishes, then activates after seeing how the card
  // actually renders. Provider Arabic copy is frequently the wrong length or
  // register, and finding that out on a live card is finding out too late.
  //
  // Unverified: a feed saying an offer exists is not verification. Marking it
  // verified here would turn "a feed mentioned this" into "we checked this".
  const r = buildCouponFromSource(normalized(), OK);
  assert.equal(r.ok, true);
  assert.equal(r.value.is_active, false);
  assert.equal(r.value.verification_state, 'unverified');
  assert.equal(r.value.source, 'affiliate');
});

test('the merchant link comes from the BOUND programme, never the payload', () => {
  // A provider's merchant reference lives in its own identifier space. Treating
  // it as ours is how an offer gets filed under the wrong business.
  const r = buildCouponFromSource(
    normalized({ merchantId: 'provider-says-this' }), OK);
  assert.equal(r.value.merchant_id, 'm-1');
});

test('a missing Arabic title is a REJECTION, not a fallback', () => {
  // Substituting the English title would hide the fact that the provider never
  // supplied Arabic copy — which the reviewer needs to know, not be shielded
  // from. And an English title inside an Arabic card reads as a bug.
  const r = buildCouponFromSource(
    normalized({ titleAr: '', titleEn: 'Great offer' }), OK);
  assert.equal(r.ok, false);
  assert.ok(codes(r).includes('title_ar:required'));
});

test('a category must be chosen by the reviewer', () => {
  // It decides which section of the app the offer appears in.
  const r = buildCouponFromSource(normalized(), { merchantId: 'm-1', displayCategoryKey: null });
  assert.equal(r.ok, false);
  assert.ok(codes(r).includes('display_category_key:required'));
});

test('an amount with no currency is rejected, never defaulted', () => {
  // Guessing SAR puts a number in front of a user in money we chose.
  const r = buildCouponFromSource(
    normalized({ benefitType: 'fixed_amount', fixedAmountMinor: 5000 }), OK);
  assert.equal(r.ok, false);
  assert.ok(codes(r).includes('benefit_currency:required_with_amount'));
});

test('an insecure URL is rejected', () => {
  // http would send a user to a downgraded connection with a coupon code on it.
  const r = buildCouponFromSource(normalized({ url: 'http://example.test/x' }), OK);
  assert.equal(r.ok, false);
  assert.ok(codes(r).includes('partner_url:insecure'));
});

test('a code offer must carry a code', () => {
  const r = buildCouponFromSource(
    normalized({ redemptionType: 'code', code: null }), OK);
  assert.equal(r.ok, false);
  assert.ok(codes(r).includes('code:required'));
});

test('the structured value passes through unchanged', () => {
  const r = buildCouponFromSource(normalized({
    benefitType: 'percent', discountBps: 2000, minSpendMinor: 20000,
    maxSavingMinor: 5000, benefitCurrency: 'SAR',
  }), OK);
  assert.equal(r.ok, true);
  assert.equal(r.value.discount_bps, 2000);
  assert.equal(r.value.max_saving_minor, 5000);
  assert.equal(r.value.benefit_currency, 'SAR');
});

test('a prose-only offer publishes with null structured fields', () => {
  // Most of a real feed. The savings layer then abstains, which is correct.
  const r = buildCouponFromSource(normalized(), OK);
  assert.equal(r.ok, true);
  assert.equal(r.value.benefit_type, null);
  assert.equal(r.value.discount_bps, null);
});

test('the slug is deterministic and derived from provider ids', () => {
  // Two publishes of the same staged offer must not create two coupons with
  // different slugs, which would leave one of them orphaned.
  assert.equal(couponSlugFor(normalized()), 'p-1-o-1');
  assert.equal(couponSlugFor(normalized()), couponSlugFor(normalized()));
});

test('a malformed payload is rejected rather than throwing', () => {
  // It arrives from a JSONB column and could be anything.
  for (const bad of [null, undefined, 'string', 42]) {
    const r = buildCouponFromSource(bad, OK);
    assert.equal(r.ok, false);
  }
});
