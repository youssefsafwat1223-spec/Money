// COUPONS Phase 2 — the deterministic fixture adapter.
//
// No affiliate network is contracted yet, so there is no real API to call. This
// adapter exists so the ENTIRE pipeline — fetch, validate, fingerprint, dedupe,
// stage, resume, review, publish — is exercised and testable end to end without
// one.
//
// It is not a mock in the testing sense: it is a real registered adapter with a
// real network key, and the worker treats it exactly like any other. That is the
// point. If the pipeline only worked once a live provider was attached, we would
// not find out until after the contract was signed.
//
// ## It must never be enabled in production
//
// Its offers are visibly synthetic, and its network row has to be created and
// promoted deliberately. The worker refuses any network whose status is
// `disabled`, and this one is intended to sit at `sandbox` permanently.

import type {
  AdapterContext,
  AffiliateAdapter,
  ConversionPage,
  NormalizedOffer,
  OfferPage,
} from './types.ts';

const CATALOG: NormalizedOffer[] = [
  {
    externalOfferId: 'fx-001',
    externalProgramId: 'fx-prog-noon',
    titleAr: 'خصم ٢٠٪ على الإلكترونيات',
    titleEn: '20% off electronics',
    descriptionAr: 'خصم على تشكيلة مختارة.',
    redemptionType: 'code',
    code: 'FIXTURE20',
    url: 'https://example.test/noon',
    benefitType: 'percent',
    discountBps: 2000,
    minSpendMinor: 20000,
    maxSavingMinor: 5000,
    benefitCurrency: 'SAR',
    markets: ['SA'],
    validFrom: '2026-01-01T00:00:00Z',
    validUntil: '2030-01-01T00:00:00Z',
    merchantNameHints: ['NOON', 'NOON KSA'],
    merchantDomainHints: ['noon.com'],
  },
  {
    externalOfferId: 'fx-002',
    externalProgramId: 'fx-prog-panda',
    titleAr: 'توصيل مجاني',
    descriptionAr: 'توصيل مجاني على الطلبات.',
    redemptionType: 'link',
    url: 'https://example.test/panda',
    benefitType: 'free_shipping',
    markets: ['SA', 'EG'],
    merchantNameHints: ['بنده'],
  },
  {
    // Prose-only: no structured value at all. This is the common real-world
    // shape, and it must survive validation untouched — a pipeline that only
    // accepts fully-structured offers would reject most of a real feed.
    externalOfferId: 'fx-003',
    externalProgramId: 'fx-prog-noon',
    titleAr: 'عروض نهاية الأسبوع',
    descriptionAr: 'التفاصيل في صفحة الشريك.',
    redemptionType: 'link',
    url: 'https://example.test/weekend',
    markets: ['SA'],
    merchantNameHints: ['NOON'],
  },
  {
    // DELIBERATELY MALFORMED: a percent with no rate. Present so the pipeline's
    // per-offer rejection path is exercised on every single run — a feed that
    // never contains a bad row lets a broken validator look healthy indefinitely.
    externalOfferId: 'fx-004',
    externalProgramId: 'fx-prog-noon',
    titleAr: 'عرض غير صالح',
    descriptionAr: 'صف غير مكتمل من المزوّد.',
    redemptionType: 'link',
    url: 'https://example.test/broken',
    benefitType: 'percent',
    markets: ['SA'],
  },
];

/// The fixture conversions report.
///
/// Deliberately contains a status the pipeline must REFUSE to apply on top of a
/// terminal-negative one, and a malformed row, for the same reason the offer
/// catalog does: a feed that is always clean lets a broken validator and a
/// broken transition rule both look healthy forever.
const CONVERSIONS: ConversionPage['conversions'] = [
  {
    externalConversionId: 'fx-conv-001',
    clickId: null,
    status: 'approved',
    orderAmountMinor: 45000,
    orderCurrency: 'SAR',
    commissionAmountMinor: 2250,
    commissionCurrency: 'SAR',
    providerDiscountMinor: 9000,
    providerDiscountCurrency: 'SAR',
    occurredAt: '2026-02-01T10:00:00Z',
  },
  {
    // Pending with no amounts. The common early shape: a sale is known before
    // its value is confirmed, and the savings math must abstain on it rather
    // than render a zero.
    externalConversionId: 'fx-conv-002',
    clickId: null,
    status: 'pending',
  },
  {
    // DELIBERATELY MALFORMED: an amount with no currency. Three-valued CHECK
    // logic already caught this class once at the database layer; it is
    // exercised here at the application layer on every run.
    externalConversionId: 'fx-conv-003',
    clickId: null,
    status: 'approved',
    commissionAmountMinor: 100,
    commissionCurrency: null,
  },
];

export class FixtureAffiliateAdapter implements AffiliateAdapter {
  readonly networkKey = 'fixture';
  readonly version = 1;

  fetchOffers(ctx: AdapterContext): Promise<OfferPage> {
    // The cursor is an index into the fixed catalog. Simple, but it exercises
    // the real resume path: the worker stores whatever string comes back and
    // hands it to the next run without interpreting it.
    const start = ctx.cursor == null ? 0 : Number.parseInt(ctx.cursor, 10);
    if (!Number.isInteger(start) || start < 0) {
      // A corrupt cursor must NOT silently restart the feed. That would
      // re-ingest everything and show up as a burst of new offers, which is
      // indistinguishable from a provider actually publishing a lot.
      return Promise.reject(new Error('invalid_cursor'));
    }
    const end = Math.min(start + ctx.limit, CATALOG.length);
    return Promise.resolve({
      offers: CATALOG.slice(start, end),
      nextCursor: end >= CATALOG.length ? null : String(end),
    });
  }

  fetchConversions(ctx: AdapterContext): Promise<ConversionPage> {
    const start = ctx.cursor == null ? 0 : Number.parseInt(ctx.cursor, 10);
    if (!Number.isInteger(start) || start < 0) {
      return Promise.reject(new Error('invalid_cursor'));
    }
    const end = Math.min(start + ctx.limit, CONVERSIONS.length);
    return Promise.resolve({
      conversions: CONVERSIONS.slice(start, end),
      nextCursor: end >= CONVERSIONS.length ? null : String(end),
    });
  }
}

/** Exposed so tests can assert against the whole fixture set. */
export const FIXTURE_OFFER_COUNT = CATALOG.length;
/** How many fixture offers are deliberately invalid. */
export const FIXTURE_INVALID_COUNT = 1;
/** How many fixture conversions there are, and how many are invalid. */
export const FIXTURE_CONVERSION_COUNT = CONVERSIONS.length;
export const FIXTURE_INVALID_CONVERSION_COUNT = 1;
