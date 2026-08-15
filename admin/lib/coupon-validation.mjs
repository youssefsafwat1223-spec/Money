// Coupons Phase C3 — the ONE authoritative server-side validation schema for
// the Coupon Admin API. Both the create and the update route use it; the client
// form may mirror it for UX, but the server is always the authority and the
// database CHECKs (0081) are the final line.
//
// Plain JS (tsconfig allowJs) so the TypeScript routes and the node:test suite
// share exactly the same code — no second, drifting schema, and no new
// dependency added to the admin bundle.

/** Mirrors 0081 coupons_slug_shape. */
const SLUG_RE = /^[a-z0-9][a-z0-9_-]{1,63}$/;
/** Mirrors 0081 coupon_categories_key_shape. */
const CATEGORY_KEY_RE = /^[a-z0-9_]{2,32}$/;
/** Mirrors 0081 coupon_tags_key_shape (Arabic keys permitted). */
const TAG_KEY_RE = /^[a-z0-9_؀-ۿ]{2,32}$/;
const HEX_RE = /^#[0-9A-Fa-f]{6}$/;
const ISO_COUNTRY_RE = /^[A-Z]{2}$/;

/**
 * Admin-side priority bounds. 0081 deliberately has no CHECK on priority, so
 * this is an Admin guard only (no migration is added in C3). Whether the
 * database should also constrain it is reported as a follow-up consideration.
 */
export const PRIORITY_MIN = -1000;
export const PRIORITY_MAX = 1000;

export const MAX_IMAGE_BYTES = 512 * 1024;
export const IMAGE_MIME_ALLOWLIST = ['image/webp', 'image/png', 'image/jpeg'];
/** MIME -> the single normalized extension the server will use. */
export const IMAGE_EXTENSION = { 'image/webp': 'webp', 'image/png': 'png', 'image/jpeg': 'jpg' };

const isString = (v) => typeof v === 'string';
const trimmed = (v) => (isString(v) ? v.trim() : '');
const nonBlank = (v) => trimmed(v).length > 0;
const orNull = (v) => (nonBlank(v) ? v.trim() : null);

/** Normalize a human string into a slug candidate (Admin convenience). */
export function normalizeSlug(input) {
  return trimmed(input)
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 64);
}

/**
 * Normalize a tag key: lowercase, trim, collapse whitespace to '_'. Arabic is
 * preserved so an Arabic-first label can produce a usable key.
 */
export function normalizeTagKey(input) {
  return trimmed(input)
    .toLowerCase()
    .replace(/\s+/g, '_')
    .replace(/[^a-z0-9_؀-ۿ]/g, '')
    .slice(0, 32);
}

/**
 * Destination URL validation — deliberately STRICTER than the database's
 * minimal `LIKE 'https://%'` guard. Uses a real URL parser.
 * Rejected: non-https schemes (http/javascript/data/file/…), malformed URLs,
 * embedded credentials, and localhost / private / link-local hosts.
 * The destination is NEVER fetched server-side (no SSRF surface).
 */
export function validateDestinationUrl(value) {
  const raw = trimmed(value);
  if (!raw) return { ok: false, error: 'invalid_url' };
  let url;
  try {
    url = new URL(raw);
  } catch {
    return { ok: false, error: 'invalid_url' };
  }
  if (url.protocol !== 'https:') return { ok: false, error: 'url_not_https' };
  if (url.username || url.password) return { ok: false, error: 'url_has_credentials' };
  const host = url.hostname.toLowerCase();
  const isPrivate =
    host === 'localhost' ||
    host === '::1' ||
    host.endsWith('.local') ||
    host.endsWith('.internal') ||
    /^127\./.test(host) ||
    /^10\./.test(host) ||
    /^192\.168\./.test(host) ||
    /^169\.254\./.test(host) ||
    /^172\.(1[6-9]|2[0-9]|3[0-1])\./.test(host);
  if (isPrivate) return { ok: false, error: 'url_private_host' };
  return { ok: true, value: url.toString() };
}

/** ISO-3166-1 alpha-2, uppercase only. 'ALL' is never a country value. */
export function isIsoCountryCode(value) {
  return isString(value) && ISO_COUNTRY_RE.test(value);
}

/**
 * Validate + normalize a Coupon payload for INSERT/UPDATE.
 *
 * @param {Record<string, unknown>} input raw request body
 * @param {{ mode: 'create' | 'update' }} opts
 * @returns {{ ok: true, value: Record<string, unknown> } |
 *           { ok: false, errors: Array<{ field: string, error: string }> }}
 */
export function validateCouponPayload(input, opts = { mode: 'create' }) {
  const errors = [];
  const fail = (field, error) => errors.push({ field, error });
  const body = input && typeof input === 'object' ? input : {};

  // --- identity -------------------------------------------------------------
  const slug = trimmed(body.slug);
  if (!SLUG_RE.test(slug)) fail('slug', 'invalid_slug');
  if (!nonBlank(body.partner_name)) fail('partner_name', 'required');

  // --- content (Arabic-first; English optional) ------------------------------
  if (!nonBlank(body.title_ar)) fail('title_ar', 'required');
  if (!nonBlank(body.description_ar)) fail('description_ar', 'required');

  // --- redemption -----------------------------------------------------------
  const type = body.redemption_type;
  let code = null;
  let partnerUrl = null;
  if (type !== 'code' && type !== 'link') {
    fail('redemption_type', 'invalid_redemption_type');
  } else if (type === 'code') {
    if (!nonBlank(body.code)) fail('code', 'code_required');
    else code = trimmed(body.code).toUpperCase();
    // A code coupon MAY carry an optional secondary destination.
    if (nonBlank(body.partner_url)) {
      const u = validateDestinationUrl(body.partner_url);
      if (!u.ok) fail('partner_url', u.error);
      else partnerUrl = u.value;
    }
  } else {
    // link: destination required, code must not become a second authority.
    const u = validateDestinationUrl(body.partner_url);
    if (!u.ok) fail('partner_url', u.error);
    else partnerUrl = u.value;
    if (nonBlank(body.code)) fail('code', 'code_not_allowed_for_link');
  }

  // --- classification -------------------------------------------------------
  const categoryKey = trimmed(body.display_category_key);
  if (!CATEGORY_KEY_RE.test(categoryKey)) fail('display_category_key', 'invalid_category');

  const tagIds = Array.isArray(body.tag_ids) ? body.tag_ids.filter(isString) : [];

  // Spend hints are OPTIONAL, unvalidated-by-FK metadata: unknown or stale keys
  // stay legal (they simply produce no on-device ranking boost) so editing an
  // old coupon never breaks.
  const spendHints = Array.isArray(body.spend_hint_category_keys)
    ? [...new Set(body.spend_hint_category_keys.filter(nonBlank).map((h) => h.trim()))]
    : [];

  // --- availability ---------------------------------------------------------
  const isGlobal = body.is_global === true;
  let countries = [];
  if (!isGlobal) {
    const raw = Array.isArray(body.country_codes) ? body.country_codes : [];
    countries = [...new Set(raw.filter(isString).map((c) => c.trim().toUpperCase()))];
    if (countries.length === 0) fail('country_codes', 'countries_required_when_not_global');
    if (!countries.every(isIsoCountryCode)) fail('country_codes', 'invalid_country_code');
  }

  const validFrom = parseTimestamp(body.valid_from);
  if (!validFrom) fail('valid_from', 'invalid_date');
  let validUntil = null;
  if (nonBlank(body.valid_until)) {
    validUntil = parseTimestamp(body.valid_until);
    if (!validUntil) fail('valid_until', 'invalid_date');
    else if (validFrom && validUntil <= validFrom) fail('valid_until', 'window_ends_before_start');
  }

  // --- presentation ---------------------------------------------------------
  const accent = orNull(body.accent_hex);
  if (accent !== null && !HEX_RE.test(accent)) fail('accent_hex', 'invalid_hex');

  const priority = Number(body.priority ?? 0);
  if (!Number.isInteger(priority) || priority < PRIORITY_MIN || priority > PRIORITY_MAX) {
    fail('priority', 'invalid_priority');
  }

  if (errors.length > 0) return { ok: false, errors };

  return {
    ok: true,
    value: {
      slug,
      partner_name: trimmed(body.partner_name),
      title_ar: trimmed(body.title_ar),
      title_en: orNull(body.title_en),
      description_ar: trimmed(body.description_ar),
      description_en: orNull(body.description_en),
      terms_ar: orNull(body.terms_ar),
      redemption_type: type,
      code,
      partner_url: partnerUrl,
      display_category_key: categoryKey,
      spend_hint_category_keys: spendHints,
      country_codes: countries, // [] == globally available (canonical)
      accent_hex: accent,
      featured: body.featured === true,
      priority,
      valid_from: validFrom,
      valid_until: validUntil,
      is_active: body.is_active !== false,
      // Not part of the DB row: consumed by the route to sync coupon_tag_links.
      __tag_ids: tagIds,
    },
  };
}

/**
 * Parse an Admin-supplied datetime into a canonical UTC ISO string.
 * A `datetime-local` value carries no zone; the Admin client sends an absolute
 * ISO string (it converts from browser-local before sending), and anything
 * unparseable is rejected rather than silently treated as UTC.
 */
export function parseTimestamp(value) {
  if (!isString(value) || value.trim() === '') return null;
  const d = new Date(value);
  if (Number.isNaN(d.getTime())) return null;
  return d.toISOString();
}

/** Validate a tag create payload (normalized key + Arabic label required). */
export function validateTagPayload(input) {
  const body = input && typeof input === 'object' ? input : {};
  const errors = [];
  const key = normalizeTagKey(body.key ?? body.label_ar);
  if (!TAG_KEY_RE.test(key)) errors.push({ field: 'key', error: 'invalid_tag_key' });
  if (!nonBlank(body.label_ar)) errors.push({ field: 'label_ar', error: 'required' });
  const sortOrder = Number(body.sort_order ?? 0);
  if (!Number.isInteger(sortOrder)) errors.push({ field: 'sort_order', error: 'invalid_sort_order' });
  if (errors.length) return { ok: false, errors };
  return {
    ok: true,
    value: {
      key,
      label_ar: trimmed(body.label_ar),
      label_en: orNull(body.label_en),
      sort_order: sortOrder,
    },
  };
}

/** Validate a display-category payload. */
export function validateCategoryPayload(input, opts = { mode: 'create' }) {
  const body = input && typeof input === 'object' ? input : {};
  const errors = [];
  const key = trimmed(body.key).toLowerCase();
  if (opts.mode === 'create' && !CATEGORY_KEY_RE.test(key)) {
    errors.push({ field: 'key', error: 'invalid_category_key' });
  }
  if (!nonBlank(body.label_ar)) errors.push({ field: 'label_ar', error: 'required' });
  const sortOrder = Number(body.sort_order ?? 0);
  if (!Number.isInteger(sortOrder)) errors.push({ field: 'sort_order', error: 'invalid_sort_order' });
  if (errors.length) return { ok: false, errors };
  return {
    ok: true,
    value: {
      ...(opts.mode === 'create' ? { key } : {}),
      label_ar: trimmed(body.label_ar),
      label_en: orNull(body.label_en),
      sort_order: sortOrder,
      is_active: body.is_active !== false,
    },
  };
}

/**
 * Image validation performed BEFORE any Storage upload: size, declared MIME
 * against the allowlist, and the actual file signature (magic bytes). SVG and
 * HTML/markup are rejected outright — there is no sanitizer, and the bucket is
 * public-read.
 *
 * Pixel dimensions are NOT inspected here: no image-decoding dependency exists
 * in the admin app and adding one for this alone was out of scope for C3, so
 * the approved dimension guidance stays ADVISORY (surfaced in the Admin UI).
 *
 * @param {{ size: number, mime: string, bytes: Uint8Array }} file
 */
export function validateImageUpload(file) {
  const { size, mime, bytes } = file ?? {};
  if (typeof size !== 'number' || size <= 0) return { ok: false, error: 'image_empty' };
  if (size > MAX_IMAGE_BYTES) return { ok: false, error: 'image_too_large' };
  if (!IMAGE_MIME_ALLOWLIST.includes(mime)) return { ok: false, error: 'image_mime_not_allowed' };
  if (!bytes || bytes.length < 12) return { ok: false, error: 'image_unreadable' };

  const sig = detectImageSignature(bytes);
  if (sig === null) return { ok: false, error: 'image_signature_unknown' };
  if (sig !== mime) return { ok: false, error: 'image_signature_mismatch' };
  return { ok: true, extension: IMAGE_EXTENSION[mime] };
}

/** Identify a supported raster image by its magic bytes (null when unknown). */
export function detectImageSignature(bytes) {
  const b = bytes;
  const starts = (...sig) => sig.every((v, i) => b[i] === v);
  if (starts(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a)) return 'image/png';
  if (starts(0xff, 0xd8, 0xff)) return 'image/jpeg';
  // RIFF....WEBP
  if (
    starts(0x52, 0x49, 0x46, 0x46) &&
    b[8] === 0x57 && b[9] === 0x45 && b[10] === 0x42 && b[11] === 0x50
  ) {
    return 'image/webp';
  }
  return null;
}

/**
 * The Storage object key is ALWAYS derived by the server from the coupon id and
 * the validated MIME. A client-supplied filename, directory or extension can
 * never influence it, so traversal ('../'), foreign prefixes and overwriting
 * another coupon's asset are impossible by construction.
 */
export function storageObjectPath(couponId, extension) {
  if (!/^[0-9a-f-]{36}$/i.test(String(couponId ?? ''))) return null;
  if (!Object.values(IMAGE_EXTENSION).includes(extension)) return null;
  return `coupons/${couponId}/art.${extension}`;
}

/** Derived status — the SAME semantics as 0081 public.coupon_is_live. */
export function couponStatus(coupon, now = new Date()) {
  if (!coupon?.is_active) return 'disabled';
  const from = new Date(coupon.valid_from);
  const until = coupon.valid_until ? new Date(coupon.valid_until) : null;
  if (from > now) return 'scheduled';           // valid_from is INCLUSIVE
  if (until && until <= now) return 'expired';  // valid_until is EXCLUSIVE
  return 'live';
}

/** Controlled sort mapping — a client can never send a raw SQL column name. */
export const COUPON_SORTS = {
  priority: { column: 'priority', ascending: false },
  newest: { column: 'created_at', ascending: false },
  updated: { column: 'updated_at', ascending: false },
  validity: { column: 'valid_from', ascending: false },
  title: { column: 'title_ar', ascending: true },
};

export function resolveSort(key) {
  return COUPON_SORTS[key] ?? COUPON_SORTS.priority;
}
