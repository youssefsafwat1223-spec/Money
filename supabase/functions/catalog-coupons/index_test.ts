// Coupons Phase C2 — catalog-coupons contract tests (§29 matrix).
// The mapping/ordering/fail-safe logic is exercised through the exported pure
// helpers; the query-level visibility predicate and the no-side-effect rule are
// locked as source contracts (they cannot be observed without a live DB).
import {
  assert,
  assertEquals,
  assertStringIncludes,
} from 'https://deno.land/std@0.224.0/assert/mod.ts';
import {
  buildSnapshot,
  COUPON_SELECT,
  type CouponSnapshotItem,
  isIsoCountryCode,
  mapCouponRow,
  orderCoupons,
  orderTags,
} from './index.ts';

const SOURCE = Deno.readTextFileSync(new URL('./index.ts', import.meta.url));

/**
 * Source with comments removed, so a contract assertion tests CODE and never
 * documentation prose (the file legitimately *describes* what it must not do).
 * Trailing `//` is stripped only when it is not part of a `://` URL.
 */
const CODE = SOURCE.split('\n')
  .map((l) => l.replace(/(^|[^:])\/\/.*$/, '$1'))
  .filter((l) => {
    const t = l.trim();
    return !t.startsWith('*') && !t.startsWith('/*') && !t.startsWith('*/');
  })
  .join('\n');

const NOW = '2026-08-15T00:00:00.000Z';

function row(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    id: '11111111-1111-1111-1111-111111111111',
    slug: 'partner-offer',
    partner_name: 'Partner',
    title_ar: 'عنوان',
    title_en: null,
    description_ar: 'وصف',
    description_en: null,
    redemption_type: 'code',
    code: 'SAVE20',
    partner_url: null,
    spend_hint_category_keys: [],
    country_codes: [],
    accent_hex: '#112233',
    image_path: null,
    featured: false,
    priority: 0,
    valid_from: '2026-08-01T00:00:00.000Z',
    valid_until: null,
    terms_ar: null,
    display_category: { key: 'food', label_ar: 'مطاعم', label_en: 'Food', is_active: true },
    coupon_tag_links: [],
    ...overrides,
  };
}

// --- A/B: both redemption shapes survive mapping ------------------------------
Deno.test('A: a live CODE coupon is returned with its code and no forced url', () => {
  const item = mapCouponRow(row())!;
  assertEquals(item.redemption_type, 'code');
  assertEquals(item.code, 'SAVE20');
  assertEquals(item.partner_url, null);
});

Deno.test('B: a live LINK coupon is returned with its https destination, code null', () => {
  const item = mapCouponRow(
    row({ redemption_type: 'link', code: null, partner_url: 'https://example.com' }),
  )!;
  assertEquals(item.redemption_type, 'link');
  assertEquals(item.code, null);
  assertEquals(item.partner_url, 'https://example.com');
});

Deno.test('B2: a code coupon MAY carry an optional secondary url', () => {
  const item = mapCouponRow(row({ partner_url: 'https://example.com' }))!;
  assertEquals(item.partner_url, 'https://example.com');
});

// --- C/D/E: non-live rows never leave the database (source contract) ----------
Deno.test('C/D/E: the query applies the canonical live predicate (0081 semantics)', () => {
  assertStringIncludes(SOURCE, ".eq('is_active', true)");
  assertStringIncludes(SOURCE, ".lte('valid_from', now)");
  // EXCLUSIVE end boundary: gt, never gte (campaigns uses gte — not copied).
  assertStringIncludes(SOURCE, 'valid_until.is.null,valid_until.gt.${now}');
  assert(
    !SOURCE.includes('valid_until.gte.'),
    'valid_until must be exclusive (gt), matching public.coupon_is_live',
  );
  // A deactivated display category is not live content either — enforced by
  // the mapper (see G2) with `!inner` guaranteeing the embed exists, so no
  // unverifiable embedded-alias filter syntax is relied upon.
  assertStringIncludes(SOURCE, 'coupon_categories!inner');
});

// --- F: empty catalog is success ---------------------------------------------
Deno.test('F: an empty live catalog is a successful empty snapshot', () => {
  const snap = buildSnapshot([], NOW);
  assertEquals(snap.items, []);
  assertEquals(snap.meta.count, 0);
  assertEquals(snap.meta.generated_at, NOW);
});

// --- G: category embedding ----------------------------------------------------
Deno.test('G: the display category is embedded with its labels', () => {
  const item = mapCouponRow(row())!;
  assertEquals(item.display_category, { key: 'food', label_ar: 'مطاعم', label_en: 'Food' });
});

Deno.test('G2: a row whose display category is deactivated is EXCLUDED (fail-safe)', () => {
  const dropped = mapCouponRow(
    row({ display_category: { key: 'food', label_ar: 'مطاعم', label_en: null, is_active: false } }),
  );
  assertEquals(dropped, null);
  // …and never silently remapped onto another category.
  assert(!CODE.includes('fallbackCategory') && !CODE.includes('default_category'));
});

// --- H: deterministic normalized tag order ------------------------------------
Deno.test('H: tags are ordered sort_order ASC then key ASC', () => {
  const ordered = orderTags([
    { key: 'zeta', label_ar: 'ز', label_en: null, sort_order: 2 },
    { key: 'beta', label_ar: 'ب', label_en: null, sort_order: 1 },
    { key: 'alpha', label_ar: 'أ', label_en: null, sort_order: 1 },
  ]);
  assertEquals(ordered.map((t) => t.key), ['alpha', 'beta', 'zeta']);
  // sort_order is an internal ordering field: it is not emitted.
  assertEquals(Object.keys(ordered[0]).sort(), ['key', 'label_ar', 'label_en']);
});

Deno.test('H2: only tags linked to the coupon are exposed, malformed ones dropped', () => {
  const item = mapCouponRow(
    row({
      coupon_tag_links: [
        { tag: { key: 'food', label_ar: 'مطاعم', label_en: null, sort_order: 1 } },
        { tag: { key: '', label_ar: 'broken', sort_order: 0 } }, // malformed => dropped
        { tag: null },
      ],
    }),
  )!;
  assertEquals(item.tags.map((t) => t.key), ['food']);
});

// --- I: spend hints are static passthrough ------------------------------------
Deno.test('I: spend hints pass through unchanged and are never personalized', () => {
  const item = mapCouponRow(row({ spend_hint_category_keys: ['restaurants', 'groceries'] }))!;
  assertEquals(item.spend_hint_category_keys, ['restaurants', 'groceries']);
  // The function must never read user financial data to build the snapshot.
  for (const forbidden of ['user_transactions', 'amount_minor', 'spend', 'transactions']) {
    assert(
      !CODE.toLowerCase().includes(`from('${forbidden}`),
      `catalog-coupons must not query ${forbidden}`,
    );
  }
});

// --- J/K: country serialization ------------------------------------------------
Deno.test('J: global availability serializes as an empty list (never "ALL")', () => {
  const item = mapCouponRow(row({ country_codes: [] }))!;
  assertEquals(item.country_codes, []);
  assert(!CODE.includes("'ALL'"), "the literal 'ALL' must not appear in code");
});

Deno.test('K: scoped countries stay uppercase ISO; malformed values drop the row', () => {
  assertEquals(mapCouponRow(row({ country_codes: ['SA', 'AE'] }))!.country_codes, ['SA', 'AE']);
  assertEquals(mapCouponRow(row({ country_codes: ['ALL'] })), null);
  assertEquals(mapCouponRow(row({ country_codes: ['sa'] })), null);
  assertEquals(isIsoCountryCode('SA'), true);
  assertEquals(isIsoCountryCode('ALL'), false);
});

// --- L: no admin/analytics/secret leakage --------------------------------------
Deno.test('L: the snapshot exposes only the approved mobile fields', () => {
  const item = mapCouponRow(row())!;
  assertEquals(Object.keys(item).sort(), [
    'accent_hex', 'code', 'country_codes', 'description_ar', 'description_en',
    'display_category', 'featured', 'id', 'image_path', 'partner_name',
    'partner_url', 'priority', 'redemption_type', 'slug',
    'spend_hint_category_keys', 'tags', 'terms_ar', 'title_ar', 'title_en',
    'valid_from', 'valid_until',
  ]);
  // Admin/audit/analytics columns are not even selected.
  for (const leaked of ['created_at', 'updated_at', 'coupon_metrics']) {
    assert(!COUPON_SELECT.includes(leaked), `${leaked} must not be selected`);
  }
  // `count` as a standalone column (country_codes legitimately contains "count").
  assert(!/\bcount\b/.test(COUPON_SELECT), 'no analytics count column selected');
  assert(!/\bis_active\b/.test(COUPON_SELECT.split('display_category')[0]),
    'the coupon is_active flag is not exposed to clients');
});

// --- M: deterministic ordering ---------------------------------------------------
Deno.test('M: featured DESC, priority DESC, valid_from DESC, id ASC', () => {
  const mk = (o: Partial<CouponSnapshotItem>) => mapCouponRow(row(o as Record<string, unknown>))!;
  const items = [
    mk({ id: 'b', slug: 'b', featured: false, priority: 1, valid_from: '2026-01-01T00:00:00.000Z' }),
    mk({ id: 'a', slug: 'a', featured: false, priority: 1, valid_from: '2026-01-01T00:00:00.000Z' }),
    mk({ id: 'c', slug: 'c', featured: false, priority: 5, valid_from: '2026-01-01T00:00:00.000Z' }),
    mk({ id: 'd', slug: 'd', featured: true, priority: 0, valid_from: '2026-01-01T00:00:00.000Z' }),
    mk({ id: 'e', slug: 'e', featured: false, priority: 1, valid_from: '2026-06-01T00:00:00.000Z' }),
  ];
  assertEquals(orderCoupons(items).map((i) => i.id), ['d', 'c', 'e', 'a', 'b']);
  // stable: ordering the already-ordered list is a no-op
  assertEquals(orderCoupons(orderCoupons(items)).map((i) => i.id), ['d', 'c', 'e', 'a', 'b']);
});

// --- N: no analytics side effect on fetch ------------------------------------------
Deno.test('N: fetching the catalog records no analytics/engagement event', () => {
  for (const sideEffect of [
    'record_coupon_event', 'record_engagement_event', 'coupon_metrics_daily',
    'evaluate-budgets', 'evaluate-goals', 'gamification', 'sendCapturePush',
  ]) {
    assert(!CODE.includes(sideEffect), `catalog-coupons must not invoke ${sideEffect}`);
  }
  // The function performs no write of any kind.
  for (const write of ['.insert(', '.update(', '.upsert(', '.delete(', '.rpc(']) {
    assert(!CODE.includes(write), `catalog-coupons must not call ${write}`);
  }
});

// --- O: fail-safe exclusion of malformed rows -----------------------------------
Deno.test('O: malformed catalog rows are excluded, not exposed broken', () => {
  const bad: Array<[string, Record<string, unknown>]> = [
    ['missing id', { id: '' }],
    ['blank title_ar', { title_ar: '  ' }],
    ['blank description_ar', { description_ar: '' }],
    ['blank partner', { partner_name: '' }],
    ['unknown redemption type', { redemption_type: 'voucher' }],
    ['code type without code', { redemption_type: 'code', code: null }],
    ['link without destination', { redemption_type: 'link', code: null, partner_url: null }],
    ['link carrying a contradictory code', {
      redemption_type: 'link', code: 'X', partner_url: 'https://e.com',
    }],
    ['non-https destination', { partner_url: 'http://example.com' }],
    ['javascript: destination', { partner_url: 'javascript:alert(1)' }],
    ['missing category', { display_category: null }],
  ];
  for (const [label, override] of bad) {
    assertEquals(mapCouponRow(row(override)), null, `${label} must be excluded`);
  }
  // A page of mixed rows keeps only the good ones, and count matches.
  const snap = buildSnapshot([row(), row({ id: 'x', slug: 'x', redemption_type: 'voucher' })], NOW);
  assertEquals(snap.items.length, 1);
  assertEquals(snap.meta.count, 1);
});
