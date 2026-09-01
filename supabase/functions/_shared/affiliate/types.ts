// COUPONS Phase 2 — the provider-neutral affiliate contract.
//
// Every partner network has its own payload shape, its own idea of what a
// "discount" is, its own pagination and its own notion of an id. An adapter's
// job is to turn all of that into ONE shape, so nothing downstream — dedupe,
// review, publish — ever branches on which network a row came from.
//
// The rule that makes this worth doing: a NEW NETWORK MUST BE A NEW ADAPTER AND
// NOTHING ELSE. If adding a provider requires touching the worker, the review
// queue or the admin panel, the abstraction has failed and the second provider
// will cost as much as the first.

/** A market-scoped, already-validated offer as the pipeline understands it. */
export interface NormalizedOffer {
  /** The provider's own id. Stable across runs, or dedupe cannot work. */
  externalOfferId: string;
  /** The provider's programme id, so the offer can be bound to a merchant. */
  externalProgramId: string;

  titleAr: string;
  titleEn?: string | null;
  descriptionAr: string;
  descriptionEn?: string | null;
  termsAr?: string | null;

  /** `code` needs a code; `link` needs a url. Enforced by validateOffer. */
  redemptionType: 'code' | 'link';
  code?: string | null;
  /** HTTPS only. A provider that sends http is a provider sending users to a
   *  downgraded connection with a coupon code attached. */
  url?: string | null;

  /** Structured value, matching the 0095 columns. All optional: a provider that
   *  only supplies prose is normal, and inventing a number to fill the gap is
   *  how a savings figure becomes fiction. */
  benefitType?: 'percent' | 'fixed_amount' | 'free_shipping' | 'other' | null;
  discountBps?: number | null;
  fixedAmountMinor?: number | null;
  minSpendMinor?: number | null;
  maxSavingMinor?: number | null;
  benefitCurrency?: string | null;

  /** ISO-3166 alpha-2, uppercase. Empty means the provider did not say — NOT
   *  "global": an offer with an unknown market is a review question. */
  markets: string[];

  validFrom?: string | null;
  validUntil?: string | null;

  /** Merchant NAMES the provider associates with this offer. They become
   *  UNREVIEWED alias candidates, never reviewed aliases: a provider's idea of
   *  a merchant name is a suggestion, and treating it as identity is how a
   *  user's spending gets attributed to the wrong business. */
  merchantNameHints?: string[];
  /** Merchant domains, same status. */
  merchantDomainHints?: string[];
}

/** One page of a provider's feed. */
export interface OfferPage {
  offers: NormalizedOffer[];
  /** Opaque. The worker stores it and hands it back; only the adapter reads it.
   *  Null means the feed is exhausted. */
  nextCursor: string | null;
}

export interface AdapterContext {
  /** Opaque cursor from the previous run, or null on a first run. */
  cursor: string | null;
  /** Hard ceiling on offers this call may return. The worker enforces bounded
   *  work; an adapter that ignores this is a bug, not a preference. */
  limit: number;
  /** Provider credentials, read from Edge secrets. NEVER from a database row:
   *  a credential in a row is a credential in every backup and replica. */
  secrets: Record<string, string>;
}

export interface AffiliateAdapter {
  readonly networkKey: string;
  readonly version: number;
  /** Fetch one bounded page. May throw; the worker converts a throw into a
   *  failed run and leaves the published catalog untouched. */
  fetchOffers(ctx: AdapterContext): Promise<OfferPage>;

  /** OPTIONAL polling reconciliation.
   *
   *  Some networks push conversions to a webhook; some only expose a report you
   *  have to pull. An adapter for a push-only network simply omits this, and the
   *  worker skips it — rather than every adapter implementing a stub that
   *  returns nothing, which reads as "no conversions" and is indistinguishable
   *  from a broken poll.
   *
   *  Reconciliation matters even for push networks: webhooks are lost, and a
   *  status that never arrives leaves a user's saving stuck at pending forever. */
  fetchConversions?(ctx: AdapterContext): Promise<ConversionPage>;
}

/** One page of conversion updates. */
export interface ConversionPage {
  conversions: Array<{
    externalConversionId: string;
    clickId: string | null;
    status: 'pending' | 'approved' | 'rejected' | 'returned' | 'cancelled';
    orderAmountMinor?: number | null;
    orderCurrency?: string | null;
    commissionAmountMinor?: number | null;
    commissionCurrency?: string | null;
    providerDiscountMinor?: number | null;
    providerDiscountCurrency?: string | null;
    occurredAt?: string | null;
  }>;
  nextCursor: string | null;
}

/** Why a normalized offer was refused. Codes, never provider text. */
export type OfferRejection =
  | 'missing_external_id'
  | 'missing_program_id'
  | 'missing_title'
  | 'missing_description'
  | 'code_without_code'
  | 'link_without_url'
  | 'insecure_url'
  | 'bad_market'
  | 'bad_currency'
  | 'bad_benefit_shape'
  | 'bad_window';

const ISO_COUNTRY = /^[A-Z]{2}$/;
const ISO_CURRENCY = /^[A-Z]{3}$/;

/**
 * Validate one normalized offer.
 *
 * This runs on EVERY offer before it is staged, and a rejection drops that one
 * offer without failing the run. A provider feed reliably contains a few
 * malformed rows, and letting one of them abort the whole ingestion would mean
 * the catalog stops updating because a single partner typed a bad date.
 *
 * The checks deliberately mirror the 0095 CHECK constraints. Staging a row the
 * database would later refuse just moves the failure to publish time, where a
 * human is waiting for it.
 */
export function validateOffer(offer: NormalizedOffer): OfferRejection[] {
  const out: OfferRejection[] = [];
  const blank = (s: unknown) => typeof s !== 'string' || s.trim().length === 0;

  if (blank(offer.externalOfferId)) out.push('missing_external_id');
  if (blank(offer.externalProgramId)) out.push('missing_program_id');
  if (blank(offer.titleAr)) out.push('missing_title');
  if (blank(offer.descriptionAr)) out.push('missing_description');

  if (offer.redemptionType === 'code' && blank(offer.code)) out.push('code_without_code');
  if (offer.redemptionType === 'link' && blank(offer.url)) out.push('link_without_url');
  if (typeof offer.url === 'string' && offer.url.length > 0 &&
      !offer.url.startsWith('https://')) {
    out.push('insecure_url');
  }

  if (!Array.isArray(offer.markets) || offer.markets.some((m) => !ISO_COUNTRY.test(m))) {
    out.push('bad_market');
  }

  const hasAmount = offer.fixedAmountMinor != null || offer.minSpendMinor != null ||
    offer.maxSavingMinor != null;
  if (hasAmount && (offer.benefitCurrency == null || !ISO_CURRENCY.test(offer.benefitCurrency))) {
    // A minor-unit integer without a currency is not an amount. 0095 says the
    // same thing with a CHECK.
    out.push('bad_currency');
  }
  if (offer.benefitCurrency != null && !ISO_CURRENCY.test(offer.benefitCurrency)) {
    out.push('bad_currency');
  }

  switch (offer.benefitType) {
    case 'percent':
      if (offer.discountBps == null || offer.discountBps <= 0 ||
          offer.discountBps > 10000 || offer.fixedAmountMinor != null) {
        out.push('bad_benefit_shape');
      }
      break;
    case 'fixed_amount':
      if (offer.fixedAmountMinor == null || offer.fixedAmountMinor <= 0 ||
          offer.discountBps != null) {
        out.push('bad_benefit_shape');
      }
      break;
    case 'free_shipping':
    case 'other':
      if (offer.discountBps != null || offer.fixedAmountMinor != null) {
        out.push('bad_benefit_shape');
      }
      break;
    case null:
    case undefined:
      // Prose-only. Normal, and must stay valid.
      break;
    default:
      out.push('bad_benefit_shape');
  }
  // A cap only qualifies a percentage — 0095 forbids it elsewhere.
  if (offer.maxSavingMinor != null && offer.benefitType !== 'percent') {
    out.push('bad_benefit_shape');
  }

  if (offer.validFrom != null && Number.isNaN(Date.parse(offer.validFrom))) {
    out.push('bad_window');
  }
  if (offer.validUntil != null && Number.isNaN(Date.parse(offer.validUntil))) {
    out.push('bad_window');
  }
  if (offer.validFrom != null && offer.validUntil != null &&
      Date.parse(offer.validUntil) <= Date.parse(offer.validFrom)) {
    // A window that ends before it starts can never be live. 0081 rejects it.
    out.push('bad_window');
  }

  return out;
}
