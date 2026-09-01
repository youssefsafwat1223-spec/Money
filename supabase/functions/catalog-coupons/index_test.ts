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
  COUPON_ASSET_BUCKET,
  COUPON_ASSET_PATH_RE,
  couponAssetPublicUrl,
  buildSnapshot,
  COUPON_SELECT,
  type CouponSnapshotItem,
  isIsoCountryCode,
  mapCouponRow,
  orderCoupons,
  orderTags,
} from './index.ts';

const SOURCE = Deno.readTextFileSync(new URL('./index.ts', import.meta.url));

/** Stand-in for the trusted server-side SUPABASE_URL the handler passes in. */
const BASE = 'https://proj.supabase.co';
const PUBLIC_PREFIX = `${BASE}/storage/v1/object/public/coupon-assets/`;
const mapCouponRowB = (r: Record<string, unknown>) => mapCouponRow(r, BASE);

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
  const item = mapCouponRow(row(), BASE)!;
  assertEquals(item.redemption_type, 'code');
  assertEquals(item.code, 'SAVE20');
  assertEquals(item.partner_url, null);
});

Deno.test('B: a live LINK coupon is returned with its https destination, code null', () => {
  const item = mapCouponRowB(
    row({ redemption_type: 'link', code: null, partner_url: 'https://example.com' }),
  )!;
  assertEquals(item.redemption_type, 'link');
  assertEquals(item.code, null);
  assertEquals(item.partner_url, 'https://example.com');
});

Deno.test('B2: a code coupon MAY carry an optional secondary url', () => {
  const item = mapCouponRow(row({ partner_url: 'https://example.com' }), BASE)!;
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
  const snap = buildSnapshot([], NOW, BASE);
  assertEquals(snap.items, []);
  assertEquals(snap.meta.count, 0);
  assertEquals(snap.meta.generated_at, NOW);
});

// --- G: category embedding ----------------------------------------------------
Deno.test('G: the display category is embedded with its labels', () => {
  const item = mapCouponRow(row(), BASE)!;
  assertEquals(item.display_category, { key: 'food', label_ar: 'مطاعم', label_en: 'Food' });
});

Deno.test('G2: a row whose display category is deactivated is EXCLUDED (fail-safe)', () => {
  const dropped = mapCouponRowB(
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
  const item = mapCouponRowB(
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
  const item = mapCouponRow(row({ spend_hint_category_keys: ['restaurants', 'groceries'] }), BASE)!;
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
  const item = mapCouponRow(row({ country_codes: [] }), BASE)!;
  assertEquals(item.country_codes, []);
  assert(!CODE.includes("'ALL'"), "the literal 'ALL' must not appear in code");
});

Deno.test('K: scoped countries stay uppercase ISO; malformed values drop the row', () => {
  assertEquals(mapCouponRow(row({ country_codes: ['SA', 'AE'] }), BASE)!.country_codes, ['SA', 'AE']);
  assertEquals(mapCouponRow(row({ country_codes: ['ALL'] }), BASE), null);
  assertEquals(mapCouponRow(row({ country_codes: ['sa'] }), BASE), null);
  assertEquals(isIsoCountryCode('SA'), true);
  assertEquals(isIsoCountryCode('ALL'), false);
});

// --- L: no admin/analytics/secret leakage --------------------------------------
Deno.test('L: the snapshot exposes only the approved mobile fields', () => {
  const item = mapCouponRow(row(), BASE)!;
  // Every field a device can see is listed here on purpose: widening the
  // public DTO must be a deliberate edit, not a side effect of adding a column.
  // COUPONS Phase 1 adds the merchant link and the structured offer value.
  assertEquals(Object.keys(item).sort(), [
    'accent_hex', 'benefit_currency', 'benefit_type', 'code', 'country_codes',
    'description_ar', 'description_en', 'discount_bps', 'display_category',
    'featured', 'fixed_amount_minor', 'id', 'image_url', 'max_saving_minor',
    'merchant_id', 'merchant_name_ar', 'merchant_name_en', 'merchant_slug',
    'min_spend_minor', 'partner_name', 'partner_url', 'priority',
    'redemption_type', 'slug', 'source', 'spend_hint_category_keys', 'tags',
    'terms_ar', 'title_ar', 'title_en', 'valid_from', 'valid_until',
    'verification_state',
  ]);
  // Admin/audit/analytics columns are not even selected.
  for (const leaked of ['created_at', 'updated_at', 'coupon_metrics']) {
    assert(!COUPON_SELECT.includes(leaked), `${leaked} must not be selected`);
  }
  // `count` as a standalone column (country_codes legitimately contains "count").
  assert(!/\bcount\b/.test(COUPON_SELECT), 'no analytics count column selected');
  assert(!/\bis_active\b/.test(COUPON_SELECT.split('merchant:')[0]),
    'the coupon is_active flag is not exposed to clients');
});

// --- L2: the merchant link is dropped when the merchant is not live ------------
Deno.test('L2: a tombstoned or inactive merchant yields no merchant link', () => {
  // A coupon outlives its merchant's deactivation — the offer row is untouched
  // when a merchant is tombstoned. Serving the link anyway would let a device
  // group offers under a merchant the catalog no longer publishes, and the
  // merchant page would open onto nothing.
  for (const merchant of [
    null,
    { slug: 'x', name_ar: 'x', is_active: false, is_deleted: false },
    { slug: 'x', name_ar: 'x', is_active: true, is_deleted: true },
  ]) {
    const item = mapCouponRow(
      row({ merchant_id: 'm-1', merchant }), BASE)!;
    assertEquals(item.merchant_id, null);
    assertEquals(item.merchant_slug, null);
  }

  const live = mapCouponRow(
    row({
      merchant_id: 'm-1',
      merchant: { slug: 'noon', name_ar: 'نون', name_en: 'Noon', is_active: true, is_deleted: false },
    }),
    BASE,
  )!;
  assertEquals(live.merchant_id, 'm-1');
  assertEquals(live.merchant_slug, 'noon');
  assertEquals(live.merchant_name_ar, 'نون');
});

// --- L3: the offer keeps working with no merchant at all ----------------------
Deno.test('L3: a pre-Phase-1 offer still maps, with nulls throughout', () => {
  // The join is LEFT, not inner. An inner join would make the entire existing
  // catalog vanish the moment this deploys.
  const item = mapCouponRow(row(), BASE)!;
  assertEquals(item.merchant_id, null);
  assertEquals(item.benefit_type, null);
  assertEquals(item.source, 'manual');
  assertEquals(item.verification_state, 'unverified');
});

// --- M: deterministic ordering ---------------------------------------------------
Deno.test('M: featured DESC, priority DESC, valid_from DESC, id ASC', () => {
  const mk = (o: Partial<CouponSnapshotItem>) => mapCouponRow(row(o as Record<string, unknown>), BASE)!;
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
    assertEquals(mapCouponRow(row(override), BASE), null, `${label} must be excluded`);
  }
  // A page of mixed rows keeps only the good ones, and count matches.
  const snap = buildSnapshot([row(), row({ id: 'x', slug: 'x', redemption_type: 'voucher' })], NOW, BASE);
  assertEquals(snap.items.length, 1);
  assertEquals(snap.meta.count, 1);
});

// ---------------------------------------------------------------------------
// C5.1 — the catalog boundary owns public asset URL resolution.
// DB stores image_path; the response carries an absolute image_url; the mobile
// client never learns the bucket layout.
// ---------------------------------------------------------------------------
const IMG = 'coupons/11111111-1111-1111-1111-111111111111/art.png';

Deno.test('C5.1 A: a null image_path yields a null image_url (no guessed URL)', () => {
  const item = mapCouponRow(row({ image_path: null }), BASE)!;
  assertEquals(item.image_url, null);
  // and nothing bucket-shaped leaked into the payload
  assertEquals(JSON.stringify(item).includes(COUPON_ASSET_BUCKET), false);
});

Deno.test('C5.1 B: a valid path becomes an absolute HTTPS public URL', () => {
  const item = mapCouponRow(row({ image_path: IMG }), BASE)!;
  assertEquals(item.image_url, `${PUBLIC_PREFIX}${IMG}`);
  assertEquals(item.image_url!.startsWith('https://'), true);
});

Deno.test('C5.1 C: the URL points at the coupon-assets bucket public route', () => {
  const item = mapCouponRow(row({ image_path: IMG }), BASE)!;
  assertEquals(item.image_url!.includes(`/storage/v1/object/public/${COUPON_ASSET_BUCKET}/`), true);
});

Deno.test('C5.1 E: a malformed image_path rejects the ROW, never emits a URL', () => {
  for (const bad of [
    'art.png',                                   // no coupons/ prefix
    'coupons/not-a-uuid/art.png',                // bad id segment
    'coupons/11111111-1111-1111-1111-111111111111/../../etc/passwd', // traversal
    'https://evil.example/x.png',                // absolute URL smuggled into the column
    '',                                          // empty
    42,                                          // wrong type
  ]) {
    assertEquals(mapCouponRow(row({ image_path: bad }), BASE), null, `must reject: ${bad}`);
  }
});

Deno.test('C5.1 F: the public DTO exposes image_url and NOT image_path', () => {
  const item = mapCouponRow(row({ image_path: IMG }), BASE)!;
  assertEquals(Object.hasOwn(item, 'image_url'), true);
  assertEquals(Object.hasOwn(item, 'image_path'), false, 'storage internals are not a mobile contract');
});

Deno.test('C5.1 D: no credential material can reach the response', () => {
  const item = mapCouponRow(row({ image_path: IMG }), BASE)!;
  const payload = JSON.stringify(item);
  for (const secret of ['service_role', 'apikey', 'Bearer ', 'SUPABASE_SERVICE_ROLE_KEY', 'eyJ']) {
    assertEquals(payload.includes(secret), false, `must not contain ${secret}`);
  }
  // the base is used for composition only — no token is ever appended
  assertEquals(item.image_url!.includes('?'), false, 'public URL carries no query/token');
});

Deno.test('C5.1: the path contract equals 0081 coupons_image_path_shape', () => {
  assertEquals(COUPON_ASSET_PATH_RE.test(IMG), true);
  const sql = Deno.readTextFileSync(
    new URL('../../migrations/0081_coupons.sql', import.meta.url),
  );
  // The migration's CHECK is the authority; the Edge must not be laxer.
  assertEquals(sql.includes("'^coupons/[0-9a-f-]{36}/[A-Za-z0-9_.-]+$'"), true);
});

Deno.test('C5.1: the resolver never trusts a caller-supplied base for a bad path', () => {
  assertEquals(couponAssetPublicUrl('https://attacker.example', null), { ok: true, url: null });
  assertEquals(couponAssetPublicUrl(BASE, 'nope'), { ok: false });
  // trailing slashes in the trusted base are normalized, not doubled
  const r = couponAssetPublicUrl(`${BASE}/`, IMG);
  assertEquals(r.ok && r.url, `${PUBLIC_PREFIX}${IMG}`);
});
