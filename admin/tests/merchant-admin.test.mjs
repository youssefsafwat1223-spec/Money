// COUPONS Phase 1 — merchant / alias admin validation.
//
// This schema is NOT the last line of defence and must never be treated as one.
// 0094 is: alias_normalized is a GENERATED ALWAYS column, an empty key is a
// CHECK violation, boilerplate is a trigger rejection, and one-merchant-per-
// reviewed-alias is a partial unique index. Everything here exists to turn a
// constraint name into a sentence before the admin loses their typing.
//
// So the tests below check two things: that the friendly rejections match what
// the database would reject anyway, and — the important one — that this file's
// copy of the lookup-noise lexicon still matches the migration's. Three copies
// of one lexicon exist by necessity (an IMMUTABLE SQL function for the trigger,
// an offline client, and this). Drift between them is the failure mode, so it
// is asserted rather than trusted.

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

import {
  ALIAS_KINDS,
  LOOKUP_NOISE_LEXICON,
  hasLookupNoise,
  normalizeSlug,
  validateAliasPayload,
  validateMerchantPayload,
} from '../lib/merchant-validation.mjs';

const MIGRATION = readFileSync(
  new URL('../../supabase/migrations/0094_catalog_merchants.sql', import.meta.url),
  'utf8',
);

const codes = (result) => result.fields.map((f) => `${f.field}:${f.code}`);

test('the lexicon mirrors merchant_lookup_noise_v1 in 0094', () => {
  // If someone adds a bank wrapper to the migration and not here, the admin
  // silently stops warning and the database starts rejecting writes with a
  // constraint name. If they add it here and not there, the admin refuses
  // aliases the database would happily accept.
  const fn = MIGRATION.split('merchant_lookup_noise_v1')[2] ?? MIGRATION;
  for (const wrapper of LOOKUP_NOISE_LEXICON.leadingWrappers) {
    assert.ok(fn.includes(wrapper),
      `leading wrapper "${wrapper}" is in the admin lexicon but not in 0094`);
  }
  for (const marker of LOOKUP_NOISE_LEXICON.markerWords) {
    assert.ok(fn.includes(marker),
      `marker "${marker}" is in the admin lexicon but not in 0094`);
  }
});

test('the migration requires digits after a marker, and so do we', () => {
  // text_normalizer.dart uses `[0-9]*`, which strips a bare trailing marker and
  // turns "CAFE TRACE" into "CAFE". Both the migration and this file must use
  // `+`, or a real merchant becomes uncatalogable.
  assert.ok(MIGRATION.includes('[0-9]+'), '0094 must require digits after a marker');
  assert.equal(hasLookupNoise('CAFE TRACE'), false);
  assert.equal(hasLookupNoise('CAFE TERM 4471'), true);
});

test('bank wrappers are detected, in both scripts', () => {
  for (const raw of [
    'POS PURCHASE CARREFOUR', 'CARD PURCHASE NOON', 'PAYMENT TO PANDA',
    'شراء من كارفور', 'مشتريات من بنده',
    'CARREFOUR BRANCH 12', 'مطعم فرع 45', 'SHOP REF 99',
  ]) {
    assert.equal(hasLookupNoise(raw), true, raw);
  }
});

test('real names that merely resemble noise are NOT rejected', () => {
  // Bare `payment`, `pos`, `purchase`, `شراء`, `دفع` start real businesses.
  // Rejecting them would make those merchants uncatalogable, and the resolver
  // would then abstain on them forever.
  for (const raw of [
    'PAYMENT SOLUTIONS', 'POS HOUSE', 'PURCHASE POINT', 'شراء الخير',
    'CAFE TRACE', '7-ELEVEN', 'FOREVER 21', 'STC 5G',
  ]) {
    assert.equal(hasLookupNoise(raw), false, raw);
  }
});

test('Arabic-Indic digits count as digits', () => {
  assert.equal(hasLookupNoise('بنده فرع ٤٥'), true);
});

test('an alias that folds to nothing is rejected before the round trip', () => {
  // Every one of these produces the SAME empty key. One stored row would match
  // all of them, so the database CHECK refuses it — this just says why.
  for (const raw of ['!!!', '؟؟؟', '...']) {
    const r = validateAliasPayload({ merchant_id: 'm', alias_raw: raw });
    assert.equal(r.ok, false, raw);
    assert.ok(codes(r).includes('alias_raw:folds_to_empty'), raw);
  }
  // Whitespace is caught one step earlier as simply missing, which is the
  // better message — "required" reads correctly for an empty box.
  const blank = validateAliasPayload({ merchant_id: 'm', alias_raw: '   ' });
  assert.equal(blank.ok, false);
  assert.ok(codes(blank).includes('alias_raw:required'));
});

test('a new alias is UNREVIEWED unless explicitly approved', () => {
  // Reviewing is what makes an alias visible to every device. A bulk import
  // must never be able to publish itself.
  const r = validateAliasPayload({ merchant_id: 'm', alias_raw: 'CARREFOUR' });
  assert.equal(r.ok, true);
  assert.equal(r.value.is_reviewed, false);

  const approved = validateAliasPayload(
    { merchant_id: 'm', alias_raw: 'CARREFOUR', is_reviewed: true });
  assert.equal(approved.value.is_reviewed, true);
});

test('alias_normalized is never accepted from the caller', () => {
  // Belt and braces: PostgreSQL rejects an explicit value for a GENERATED
  // ALWAYS column, but the payload must not carry one either, or the route
  // would be relying on the database to reject something it should not send.
  const r = validateAliasPayload({
    merchant_id: 'm', alias_raw: 'CARREFOUR', alias_normalized: 'anything',
  });
  assert.equal(r.ok, true);
  assert.ok(!('alias_normalized' in r.value));
});

test('a domain alias is validated as a host, not a URL', () => {
  const bad = validateAliasPayload(
    { merchant_id: 'm', alias_kind: 'domain', alias_raw: 'https://noon.com/x' });
  assert.equal(bad.ok, false);
  assert.ok(codes(bad).includes('alias_raw:expected_bare_host'));

  // `www.` is accepted and kept verbatim in alias_raw: merchant_domain_key_v1
  // strips it when DERIVING the key, so www.noon.com and noon.com produce the
  // same lookup key and an admin does not have to know which form to type.
  const withWww = validateAliasPayload(
    { merchant_id: 'm', alias_kind: 'domain', alias_raw: 'WWW.Noon.com' });
  assert.equal(withWww.ok, true);
  assert.equal(withWww.value.alias_raw, 'www.noon.com');

  const plain = validateAliasPayload(
    { merchant_id: 'm', alias_kind: 'domain', alias_raw: 'NOON.COM' });
  assert.equal(plain.ok, true);
  assert.equal(plain.value.alias_raw, 'noon.com');
});

test('domain aliases skip the name lexicon entirely', () => {
  // A host is a different contract: digits, dots and hyphens are load-bearing,
  // and none of the name-noise rules apply to one.
  const r = validateAliasPayload(
    { merchant_id: 'm', alias_kind: 'domain', alias_raw: '7eleven.com' });
  assert.equal(r.ok, true);
});

test('only the two known alias kinds exist', () => {
  assert.deepEqual([...ALIAS_KINDS].sort(), ['domain', 'name']);
  const r = validateAliasPayload(
    { merchant_id: 'm', alias_raw: 'X', alias_kind: 'regex' });
  assert.equal(r.ok, false);
  assert.ok(codes(r).includes('alias_kind:invalid_kind'));
});

test('a one-character slug is rejected, matching the CHECK', () => {
  // 0094's shape is ^[a-z0-9][a-z0-9-]{1,62}$ — at least two characters. Worth
  // pinning: it is the kind of off-by-one that only shows up as a database
  // error on the first short brand name someone tries to add.
  assert.equal(validateMerchantPayload({ slug: 'x', name_ar: 'س' }).ok, false);
  assert.equal(validateMerchantPayload({ slug: 'xx', name_ar: 'س' }).ok, true);
});

test('merchant slugs mirror the 0094 CHECK', () => {
  assert.ok(MIGRATION.includes("catalog_merchants_slug_shape"));
  const bad = validateMerchantPayload({ slug: 'A Bad Slug', name_ar: 'اسم' });
  assert.equal(bad.ok, false);
  assert.ok(codes(bad).includes('slug:invalid_slug'));

  // A slug is derived from the Arabic name when none is given, so an admin does
  // not have to invent one.
  const derived = validateMerchantPayload({ name_ar: 'كارفور', slug: '' });
  assert.equal(derived.ok, false, 'an Arabic-only name cannot produce an ASCII slug');
  assert.equal(normalizeSlug('Carrefour KSA'), 'carrefour-ksa');
});

test('a primary domain must be a bare host', () => {
  const r = validateMerchantPayload({
    slug: 'noon', name_ar: 'نون', primary_domain: 'https://noon.com',
  });
  assert.equal(r.ok, false);
  assert.ok(codes(r).includes('primary_domain:expected_bare_host'));
});

test('country codes are normalised and shape-checked', () => {
  const r = validateMerchantPayload(
    { slug: 'xx', name_ar: 'س', country_codes: ['sa', ' eg '] });
  assert.equal(r.ok, true);
  assert.deepEqual(r.value.country_codes, ['SA', 'EG']);

  const bad = validateMerchantPayload(
    { slug: 'xx', name_ar: 'س', country_codes: ['SAU'] });
  assert.equal(bad.ok, false);
});

test('a merchant is active by default and can be created minimally', () => {
  const r = validateMerchantPayload({ slug: 'noon', name_ar: 'نون' });
  assert.equal(r.ok, true);
  assert.equal(r.value.is_active, true);
  assert.equal(r.value.name_en, null);
  assert.equal(r.value.primary_domain, null);
});
