// Coupons Phase C2 — catalog-coupons: the full live Coupon catalog snapshot the
// mobile client caches (atomic replace). Mirrors the existing catalog-* Edge
// convention (CORS + `json()` + service-key client that applies visibility
// EXPLICITLY); it is not a parallel framework.
//
// V1 is a FULL SNAPSHOT, not a delta feed.
// It returns catalog content only: no analytics, no Admin audit fields, no
// secrets, no per-user personalization. Fetching it has NO side effects — it
// never records an impression or any engagement/gamification event (an API
// fetch is not a visible impression; impressions come from the mobile viewport
// rule in a later phase).
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers':
    'authorization, x-client-info, apikey, content-type, x-app-version',
  'Access-Control-Allow-Methods': 'GET, OPTIONS',
};

/** One coupon as the mobile cache consumes it (denormalized snapshot row). */
export interface CouponSnapshotItem {
  id: string;
  slug: string;
  partner_name: string;
  title_ar: string;
  title_en: string | null;
  description_ar: string;
  description_en: string | null;
  redemption_type: 'code' | 'link';
  /** Present only for redemption_type='code'. */
  code: string | null;
  /** Required for 'link'; optional secondary CTA for 'code'. */
  partner_url: string | null;
  display_category: { key: string; label_ar: string; label_en: string | null };
  /** Deterministically ordered: sort_order ASC, then key ASC. */
  tags: Array<{ key: string; label_ar: string; label_en: string | null }>;
  /** Static ranking hints (financial category keys). Never personalized here. */
  spend_hint_category_keys: string[];
  /** [] = globally available. ISO-3166-1 alpha-2 uppercase otherwise. */
  country_codes: string[];
  accent_hex: string | null;
  /**
   * ABSOLUTE public HTTPS URL of the coupon asset, or null when the coupon has
   * no image. The catalog boundary owns this resolution: the database stores a
   * storage OBJECT PATH (`coupons/{id}/art.png`) so persisted content is never
   * coupled to a project hostname or CDN layout, and the mobile client receives
   * a ready-to-load URL so it never has to know the bucket layout.
   */
  image_url: string | null;
  featured: boolean;
  priority: number;
  valid_from: string;
  valid_until: string | null;
  terms_ar: string | null;

  // COUPONS Phase 1. All nullable: an offer whose value is prose only is the
  // entire pre-Phase-1 catalog, and the client abstains on null rather than
  // inferring a number.
  merchant_id: string | null;
  merchant_slug: string | null;
  merchant_name_ar: string | null;
  merchant_name_en: string | null;
  benefit_type: string | null;
  /// Basis points: 1250 is 12.5%.
  discount_bps: number | null;
  fixed_amount_minor: number | null;
  min_spend_minor: number | null;
  max_saving_minor: number | null;
  /// Required by the database whenever any minor amount is present.
  benefit_currency: string | null;
  source: string;
  verification_state: string;
}

export interface CouponSnapshot {
  items: CouponSnapshotItem[];
  meta: { count: number; generated_at: string };
}

/**
 * Columns fetched from PostgREST. `coupon_categories!inner` makes the category
 * join mandatory, and the handler additionally filters on the category being
 * active — a coupon whose display category was deactivated is NOT live content.
 * Nothing here selects an Admin/audit column (created_at/updated_at/is_active)
 * or anything from the analytics domain.
 */
export const COUPON_SELECT = [
  'id, slug, partner_name, title_ar, title_en, description_ar, description_en',
  'redemption_type, code, partner_url',
  'spend_hint_category_keys, country_codes',
  'accent_hex, image_path, featured, priority, valid_from, valid_until, terms_ar',
  // COUPONS Phase 1 — the merchant link and the structured value (0095).
  // `merchant` is a LEFT join, deliberately not `!inner`: an offer with no
  // merchant is the entire pre-Phase-1 catalog, and an inner join would make
  // every one of them vanish the moment this deploys.
  'merchant_id, benefit_type, discount_bps, fixed_amount_minor',
  'min_spend_minor, max_saving_minor, benefit_currency, source, verification_state',
  'merchant:catalog_merchants(slug, name_ar, name_en, is_active, is_deleted)',
  'display_category:coupon_categories!inner(key, label_ar, label_en, is_active)',
  'coupon_tag_links(tag:coupon_tags(key, label_ar, label_en, sort_order))',
].join(', ');

const EVENT_FREE = true; // documents §21: this module records no analytics.

/** The one bucket coupon art may ever come from. */
export const COUPON_ASSET_BUCKET = 'coupon-assets';

/**
 * Exactly 0081's `coupons_image_path_shape`. Only a SERVER-CREATED asset path
 * is resolvable — an arbitrary string (or an absolute URL smuggled into the
 * column) must never be turned into a link we hand to clients.
 */
export const COUPON_ASSET_PATH_RE = /^coupons\/[0-9a-f-]{36}\/[A-Za-z0-9_.-]+$/;

/**
 * Resolve a stored object path to its canonical public URL.
 *
 * `{ ok: true, url: null }`  — the coupon legitimately has no image.
 * `{ ok: true, url }`        — absolute HTTPS URL under [COUPON_ASSET_BUCKET].
 * `{ ok: false }`            — malformed path; the CALLER must reject the row
 *                              rather than emit an unsafe URL.
 *
 * The base always comes from the trusted server-side SUPABASE_URL, never from a
 * request Host header, a client-supplied base, or the database row.
 */
export function couponAssetPublicUrl(
  storageBaseUrl: string,
  imagePath: unknown,
): { ok: true; url: string | null } | { ok: false } {
  if (imagePath === null || imagePath === undefined) return { ok: true, url: null };
  if (typeof imagePath !== 'string' || !COUPON_ASSET_PATH_RE.test(imagePath)) {
    return { ok: false };
  }
  const base = storageBaseUrl.replace(/\/+$/, '');
  return {
    ok: true,
    url: `${base}/storage/v1/object/public/${COUPON_ASSET_BUCKET}/${imagePath}`,
  };
}

const isNonBlank = (v: unknown): v is string =>
  typeof v === 'string' && v.trim().length > 0;

/** ISO-3166-1 alpha-2 uppercase. 'ALL' is never a valid catalog value. */
export function isIsoCountryCode(value: unknown): boolean {
  return typeof value === 'string' && /^[A-Z]{2}$/.test(value);
}

/** Deterministic tag order: sort_order ASC, then key ASC. */
export function orderTags(
  tags: Array<{ key: string; label_ar: string; label_en: string | null; sort_order?: number }>,
): Array<{ key: string; label_ar: string; label_en: string | null }> {
  return [...tags]
    .sort((a, b) => {
      const s = (a.sort_order ?? 0) - (b.sort_order ?? 0);
      return s !== 0 ? s : a.key.localeCompare(b.key);
    })
    .map(({ key, label_ar, label_en }) => ({ key, label_ar, label_en: label_en ?? null }));
}

/**
 * Map one PostgREST row to a snapshot item, or null when the row is malformed /
 * ineligible. FAIL-SAFE: a broken catalog row is EXCLUDED rather than exposed
 * (a deactivated display category, a contradictory redemption shape, a
 * non-https destination, a legacy 'ALL' country value, …). It is never silently
 * remapped onto some other category.
 */
export function mapCouponRow(
  row: Record<string, unknown>,
  storageBaseUrl: string,
): CouponSnapshotItem | null {
  if (!isNonBlank(row.id) || !isNonBlank(row.slug)) return null;
  if (!isNonBlank(row.partner_name)) return null;
  if (!isNonBlank(row.title_ar) || !isNonBlank(row.description_ar)) return null;

  const cat = row.display_category as Record<string, unknown> | null | undefined;
  if (!cat || !isNonBlank(cat.key) || !isNonBlank(cat.label_ar)) return null;
  if (cat.is_active === false) return null; // deactivated category => not live

  const type = row.redemption_type;
  if (type !== 'code' && type !== 'link') return null;
  const code = typeof row.code === 'string' && row.code.trim() !== '' ? row.code : null;
  const url = isNonBlank(row.partner_url) ? row.partner_url : null;
  if (type === 'code' && code === null) return null;              // code required
  if (type === 'link' && (url === null || code !== null)) return null; // no dual authority
  if (url !== null && !url.startsWith('https://')) return null;    // scheme safety

  const countries = Array.isArray(row.country_codes) ? row.country_codes : [];
  if (!countries.every(isIsoCountryCode)) return null;             // rejects 'ALL'/lowercase

  const hints = Array.isArray(row.spend_hint_category_keys)
    ? row.spend_hint_category_keys.filter((h): h is string => typeof h === 'string')
    : [];

  // A malformed asset path is a malformed ROW: emitting an unsafe or guessed
  // URL would be worse than dropping the coupon (same rule as the shape checks
  // above), and no absolute URL is ever accepted from the database.
  const asset = couponAssetPublicUrl(storageBaseUrl, row.image_path);
  if (!asset.ok) return null;

  const links = Array.isArray(row.coupon_tag_links) ? row.coupon_tag_links : [];
  const tags = orderTags(
    links
      .map((l) => (l as Record<string, unknown>)?.tag as Record<string, unknown> | undefined)
      .filter((t): t is Record<string, unknown> => !!t && isNonBlank(t.key) && isNonBlank(t.label_ar))
      .map((t) => ({
        key: t.key as string,
        label_ar: t.label_ar as string,
        label_en: (t.label_en as string | null) ?? null,
        sort_order: typeof t.sort_order === 'number' ? t.sort_order : 0,
      })),
  );

  return {
    id: row.id as string,
    slug: row.slug as string,
    partner_name: row.partner_name as string,
    title_ar: row.title_ar as string,
    title_en: (row.title_en as string | null) ?? null,
    description_ar: row.description_ar as string,
    description_en: (row.description_en as string | null) ?? null,
    redemption_type: type,
    code,
    partner_url: url,
    display_category: {
      key: cat.key as string,
      label_ar: cat.label_ar as string,
      label_en: (cat.label_en as string | null) ?? null,
    },
    tags,
    spend_hint_category_keys: hints,
    country_codes: countries as string[],
    accent_hex: (row.accent_hex as string | null) ?? null,
    image_url: asset.url,
    featured: row.featured === true,
    priority: typeof row.priority === 'number' ? row.priority : 0,
    valid_from: row.valid_from as string,
    valid_until: (row.valid_until as string | null) ?? null,
    terms_ar: (row.terms_ar as string | null) ?? null,
    ...merchantFields(row),
    // Structured value. Passed through verbatim — the database CHECK
    // constraints in 0095 already guarantee the shape (a percent offer has bps
    // and no fixed amount, any minor amount carries a currency), so validating
    // again here would be a second, drifting copy of the same rule. The CLIENT
    // still decodes defensively, because a client cannot assume its server is
    // the one that wrote the row.
    benefit_type: (row.benefit_type as string | null) ?? null,
    discount_bps: (row.discount_bps as number | null) ?? null,
    fixed_amount_minor: (row.fixed_amount_minor as number | null) ?? null,
    min_spend_minor: (row.min_spend_minor as number | null) ?? null,
    max_saving_minor: (row.max_saving_minor as number | null) ?? null,
    benefit_currency: (row.benefit_currency as string | null) ?? null,
    source: (row.source as string | null) ?? 'manual',
    verification_state: (row.verification_state as string | null) ?? 'unverified',
  };
}

/**
 * The merchant link, flattened, and only when the merchant is actually live.
 *
 * A coupon can outlive its merchant's deactivation — the offer row is untouched
 * when a merchant is tombstoned — so serving the link unconditionally would let
 * a device group offers under a merchant the catalog no longer publishes, and
 * the merchant page would 404 into an empty state. Dropping the link degrades
 * the offer to exactly what it was before Phase 1: still valid, still
 * displayable through `partner_name`, just not merchant-aware.
 */
type MerchantFields = Pick<
  CouponSnapshotItem,
  'merchant_id' | 'merchant_slug' | 'merchant_name_ar' | 'merchant_name_en'
>;

function merchantFields(row: Record<string, unknown>): MerchantFields {
  const merchant = row.merchant as Record<string, unknown> | null | undefined;
  const live = merchant != null &&
    merchant.is_active === true &&
    merchant.is_deleted !== true;
  if (!live) {
    return {
      merchant_id: null,
      merchant_slug: null,
      merchant_name_ar: null,
      merchant_name_en: null,
    };
  }
  return {
    merchant_id: (row.merchant_id as string | null) ?? null,
    merchant_slug: (merchant.slug as string | null) ?? null,
    merchant_name_ar: (merchant.name_ar as string | null) ?? null,
    merchant_name_en: (merchant.name_en as string | null) ?? null,
  };
}

/**
 * Deterministic catalog order (independent of the on-device contextual ranking
 * applied later): featured DESC, priority DESC, valid_from DESC, id ASC.
 */
export function orderCoupons(items: CouponSnapshotItem[]): CouponSnapshotItem[] {
  return [...items].sort((a, b) => {
    if (a.featured !== b.featured) return a.featured ? -1 : 1;
    if (a.priority !== b.priority) return b.priority - a.priority;
    if (a.valid_from !== b.valid_from) return a.valid_from < b.valid_from ? 1 : -1;
    return a.id.localeCompare(b.id);
  });
}

/** Build the response envelope: fail-safe mapping + deterministic ordering. */
export function buildSnapshot(
  rows: Array<Record<string, unknown>>,
  generatedAt: string,
  storageBaseUrl: string,
): CouponSnapshot {
  const items = orderCoupons(
    rows
      .map((row) => mapCouponRow(row, storageBaseUrl))
      .filter((i): i is CouponSnapshotItem => i !== null),
  );
  return { items, meta: { count: items.length, generated_at: generatedAt } };
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const appVersion = req.headers.get('x-app-version') ?? 'unknown';
    console.log(`catalog-coupons requested by app version: ${appVersion}`);

    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ??
      Deno.env.get('SUPABASE_ANON_KEY');
    if (!supabaseUrl || !serviceKey) {
      return json({ error: 'Supabase environment is not configured' }, 500);
    }

    const client = createClient(supabaseUrl, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    // CANONICAL visibility (0081 public.coupon_is_live): active AND
    // valid_from <= now (INCLUSIVE) AND (valid_until IS NULL OR valid_until >
    // now) (EXCLUSIVE). The service key bypasses RLS, so this predicate is
    // applied here EXPLICITLY — scheduled, expired and disabled rows must never
    // reach a client through this function. `gt` (not `gte`) is what makes the
    // end boundary exclusive; the equivalence is locked by contract tests.
    // A coupon whose display category was deactivated is NOT live content. That
    // rule is enforced by mapCouponRow (which drops the row when the embedded
    // category carries is_active=false) rather than by a PostgREST filter on an
    // aliased embedded resource: the mapper is exercised by contract tests here,
    // whereas embedded-alias filter syntax could only be validated against a
    // live PostgREST. `!inner` still guarantees the category is present.
    const now = new Date().toISOString();
    const { data, error } = await client
      .from('coupons')
      .select(COUPON_SELECT)
      .eq('is_active', true)
      .lte('valid_from', now)
      .or(`valid_until.is.null,valid_until.gt.${now}`);

    if (error) {
      // Controlled failure: log server-side detail, return an opaque message.
      console.error('catalog-coupons query failed', error.message);
      return json({ error: 'Unable to load coupon catalog' }, 500);
    }

    // An empty live catalog is a SUCCESS with an empty collection.
    const rows = (data ?? []) as unknown as Array<Record<string, unknown>>;
    return json(buildSnapshot(rows, now, supabaseUrl));
  } catch (err) {
    console.error('catalog-coupons failed', err);
    return json({ error: 'Unexpected coupon catalog failure' }, 500);
  }
});

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

export { EVENT_FREE };
