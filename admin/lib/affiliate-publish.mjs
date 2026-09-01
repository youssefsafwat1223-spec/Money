// COUPONS Phase 2 — turning a staged provider offer into a publishable coupon.
//
// Plain JS so the TypeScript route and the node:test suite share exactly the
// same code, matching coupon-validation.mjs and merchant-validation.mjs.
//
// ## What this function refuses to do
//
// It does not invent anything. A provider that supplied no Arabic title gets a
// rejection, not a machine translation or the English title copied across — the
// title is what a user reads and what the merchant is held to. A provider that
// supplied a discount with no currency gets a rejection, not a guessed SAR. A
// provider that supplied no category gets a rejection unless the reviewer picks
// one, because a wrong category is a wrong section of the app.
//
// The pattern throughout: if the reviewer has to decide something, MAKE THEM.
// The alternative is a default that is right often enough to stop being
// questioned and wrong often enough to matter.

const ISO_CURRENCY = /^[A-Z]{3}$/;
const ISO_COUNTRY = /^[A-Z]{2}$/;

const isString = (v) => typeof v === 'string';
const trimmed = (v) => (isString(v) ? v.trim() : '');
const orNull = (v) => (trimmed(v).length > 0 ? trimmed(v) : null);

/** A slug for the published coupon, derived from the provider's ids. */
export function couponSlugFor(normalized) {
  const base = `${trimmed(normalized?.externalProgramId)}-${trimmed(normalized?.externalOfferId)}`;
  return base
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 64);
}

/**
 * Build the `coupons` row for a staged offer.
 *
 * `merchantId` comes from the bound programme, never from the provider payload:
 * a provider's merchant reference is its own identifier space, and treating it
 * as ours is how an offer ends up filed under the wrong business.
 */
export function buildCouponFromSource(normalized, { merchantId, displayCategoryKey }) {
  const fields = [];
  const push = (field, code) => fields.push({ field, code });

  if (!normalized || typeof normalized !== 'object') {
    return { ok: false, fields: [{ field: 'normalized', code: 'missing' }] };
  }
  if (!merchantId) push('merchant_id', 'required');

  const titleAr = trimmed(normalized.titleAr);
  const descriptionAr = trimmed(normalized.descriptionAr);
  // No fallback to titleEn. An Arabic-first app showing an English title inside
  // an Arabic card reads as a bug, and silently substituting one hides the fact
  // that the provider never supplied Arabic copy — which is a thing the
  // reviewer should be told about, not shielded from.
  if (!titleAr) push('title_ar', 'required');
  if (!descriptionAr) push('description_ar', 'required');

  // Deliberately not defaulted. Category decides which section of the app an
  // offer appears in, and a default would be right often enough to stop being
  // questioned.
  const category = orNull(displayCategoryKey);
  if (!category) push('display_category_key', 'required');

  const redemptionType = normalized.redemptionType === 'code' ? 'code' : 'link';
  const code = orNull(normalized.code);
  const url = orNull(normalized.url);
  if (redemptionType === 'code' && !code) push('code', 'required');
  if (redemptionType === 'link' && !url) push('partner_url', 'required');
  if (url && !url.startsWith('https://')) push('partner_url', 'insecure');

  const markets = Array.isArray(normalized.markets) ? normalized.markets : [];
  if (markets.some((m) => !ISO_COUNTRY.test(m))) push('country_codes', 'invalid_country');

  const currency = orNull(normalized.benefitCurrency);
  const hasAmount = normalized.fixedAmountMinor != null ||
    normalized.minSpendMinor != null || normalized.maxSavingMinor != null;
  if (hasAmount && (!currency || !ISO_CURRENCY.test(currency))) {
    // A minor-unit integer with no currency is not an amount, and guessing one
    // puts a number in front of a user in money we chose.
    push('benefit_currency', 'required_with_amount');
  }

  if (fields.length > 0) return { ok: false, fields };

  return {
    ok: true,
    value: {
      slug: couponSlugFor(normalized),
      // partner_name mirrors the title until a reviewer edits it. The merchant
      // link is the authoritative identity; this is only the display fallback
      // for a client that has not synced the merchant catalog yet.
      partner_name: titleAr.slice(0, 80),
      merchant_id: merchantId,
      title_ar: titleAr,
      title_en: orNull(normalized.titleEn),
      description_ar: descriptionAr,
      description_en: orNull(normalized.descriptionEn),
      terms_ar: orNull(normalized.termsAr),
      redemption_type: redemptionType,
      code,
      partner_url: url,
      display_category_key: category,
      country_codes: markets,
      valid_from: normalized.validFrom ?? new Date().toISOString(),
      valid_until: normalized.validUntil ?? null,
      benefit_type: orNull(normalized.benefitType),
      discount_bps: normalized.discountBps ?? null,
      fixed_amount_minor: normalized.fixedAmountMinor ?? null,
      min_spend_minor: normalized.minSpendMinor ?? null,
      max_saving_minor: normalized.maxSavingMinor ?? null,
      benefit_currency: currency,
      source: 'affiliate',
      // A provider feed saying an offer exists is NOT verification. The offer
      // ships as unverified and the card says so; a reviewer who actually
      // checked it can promote it afterwards. Marking it verified here would
      // turn "a feed mentioned this" into "we checked this".
      verification_state: 'unverified',
      // Published INACTIVE. The reviewer publishes, then activates in the
      // coupons screen after seeing how the card actually renders — Arabic copy
      // from a provider is frequently the wrong length or the wrong register,
      // and finding that out on a live card is finding out too late.
      is_active: false,
    },
  };
}
