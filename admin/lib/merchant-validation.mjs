// COUPONS Phase 1 — the ONE authoritative server-side validation schema for the
// merchant / alias Admin API.
//
// Plain JS (tsconfig allowJs) so the TypeScript routes and the node:test suite
// share exactly the same code — no second, drifting schema, and no dependency
// added to the admin bundle. Same arrangement as coupon-validation.mjs.
//
// ## What this file is NOT
//
// It is not the last line of defence and must never be treated as one. The
// database is: 0094 derives `alias_normalized` from a GENERATED ALWAYS column,
// rejects an empty key, rejects boilerplate through a trigger, and enforces
// one-merchant-per-reviewed-alias with a partial unique index. Everything here
// exists to give an admin a good error message BEFORE the round trip — to turn
// "check violation" into "that alias still has POS PURCHASE on the front".
//
// The consequence matters: if this file and the database ever disagree, the
// database wins and this file has a bug. Never relax a rule here to make a
// write succeed.

/** Mirrors 0094 catalog_merchants_slug_shape. */
const SLUG_RE = /^[a-z0-9][a-z0-9-]{1,62}$/;
const ISO_COUNTRY_RE = /^[A-Z]{2}$/;
/** Mirrors merchant_domain_key_v1's accepted host shape. */
const HOST_RE = /^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/;

export const ALIAS_KINDS = ['name', 'domain'];
export const ALIAS_PROVENANCE = ['admin', 'provider', 'observed_candidate'];

const isString = (v) => typeof v === 'string';
const trimmed = (v) => (isString(v) ? v.trim() : '');
const nonBlank = (v) => trimmed(v).length > 0;
const orNull = (v) => (nonBlank(v) ? v.trim() : null);

/** Admin convenience: turn a human name into a slug candidate. */
export function normalizeSlug(input) {
  return trimmed(input)
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 63);
}

// ── The lookup-noise lexicon ───────────────────────────────────────────────
//
// A MIRROR of merchant_lookup_noise_v1 (0094) and MerchantLookupPipeline.v1.
// Three copies of one lexicon is two too many, but the alternatives are worse:
// the database needs it inside an IMMUTABLE function for the trigger, the
// client needs it offline, and the admin needs it to explain the rejection
// before the user loses their typing. The database remains authoritative, and
// the node test asserts this list against the migration text so a change in one
// place fails CI rather than drifting quietly.
const LEADING_WRAPPERS = [
  'pos purchase', 'card purchase', 'purchase at', 'payment to', 'point of sale',
  'شراء من', 'مشتريات من', 'عمليه شراء', 'دفع الى',
];
const MARKER_WORDS = [
  'branch', 'term', 'terminal', 'ref', 'txn', 'trace', 'auth',
  'فرع', 'ترمينال', 'مرجع',
];

/**
 * Approximates `merchant_alias_key_v1` closely enough to detect noise.
 *
 * DELIBERATELY NOT a fourth implementation of the key contract: it lowercases
 * ASCII, folds the Arabic letters the key folds, and collapses everything else
 * to spaces. It is used ONLY to decide whether to warn — never to compute a key
 * that gets stored, because the stored key comes from the database's generated
 * column and from nowhere else.
 */
function approximateKey(input) {
  const folds = {
    'أ': 'ا', 'إ': 'ا', 'آ': 'ا', 'ٱ': 'ا', 'ة': 'ه',
    'ى': 'ي', 'ؤ': 'و', 'ئ': 'ي', 'ک': 'ك', 'ی': 'ي',
  };
  let out = '';
  for (const ch of trimmed(input).toLowerCase()) {
    const code = ch.codePointAt(0);
    // Arabic diacritics and tatweel vanish.
    if ((code >= 0x0610 && code <= 0x061a) || (code >= 0x064b && code <= 0x065f) ||
        code === 0x0670 || code === 0x0640) continue;
    const folded = folds[ch] ?? ch;
    // Arabic-Indic digits fold to ASCII and are KEPT.
    if (code >= 0x0660 && code <= 0x0669) { out += String(code - 0x0660); continue; }
    if (code >= 0x06f0 && code <= 0x06f9) { out += String(code - 0x06f0); continue; }
    const f = folded.codePointAt(0);
    const keep = (f >= 0x30 && f <= 0x39) || (f >= 0x61 && f <= 0x7a) ||
      (f >= 0x0620 && f <= 0x06ff);
    out += keep ? folded : ' ';
  }
  return out.replace(/ +/g, ' ').trim();
}

/**
 * True when an alias contains something the device would strip before looking
 * it up — a bank wrapper, or a marker followed by digits.
 *
 * Storing one is what makes the same string resolve differently depending on
 * which pipeline stage matched it, so the database refuses it. This just gets
 * the admin a sentence instead of a constraint name.
 */
export function hasLookupNoise(aliasRaw) {
  const key = approximateKey(aliasRaw);
  if (!key) return false;
  for (const wrapper of LEADING_WRAPPERS) {
    if (key.startsWith(`${wrapper} `)) return true;
  }
  for (const marker of MARKER_WORDS) {
    // Digits REQUIRED. Without them, "CAFE TRACE" would be rejected as noise
    // when it is simply a merchant with an unfortunate name.
    if (new RegExp(`(^| )${marker} [0-9]+( |$)`).test(key)) return true;
  }
  return false;
}

/** Exposed so the contract test can assert this mirror against the migration. */
export const LOOKUP_NOISE_LEXICON = Object.freeze({
  leadingWrappers: Object.freeze([...LEADING_WRAPPERS]),
  markerWords: Object.freeze([...MARKER_WORDS]),
});

export function validateMerchantPayload(body) {
  const fields = [];
  const push = (field, code) => fields.push({ field, code });

  const slugInput = trimmed(body?.slug) || normalizeSlug(body?.name_ar);
  if (!SLUG_RE.test(slugInput)) push('slug', 'invalid_slug');
  if (!nonBlank(body?.name_ar)) push('name_ar', 'required');

  const domain = orNull(body?.primary_domain);
  if (domain !== null && !HOST_RE.test(domain.toLowerCase())) {
    // A URL is the likely mistake, so the code says "host" rather than
    // "invalid": the admin needs to know to paste noon.com, not
    // https://noon.com/offers.
    push('primary_domain', 'expected_bare_host');
  }

  const countries = Array.isArray(body?.country_codes) ? body.country_codes : [];
  const normalizedCountries = countries
    .map((c) => trimmed(c).toUpperCase())
    .filter((c) => c.length > 0);
  if (normalizedCountries.some((c) => !ISO_COUNTRY_RE.test(c))) {
    push('country_codes', 'invalid_country');
  }

  if (fields.length > 0) return { ok: false, fields };

  return {
    ok: true,
    value: {
      slug: slugInput,
      name_ar: trimmed(body.name_ar),
      name_en: orNull(body?.name_en),
      primary_domain: domain === null ? null : domain.toLowerCase(),
      default_display_category_key: orNull(body?.default_display_category_key),
      country_codes: normalizedCountries,
      is_active: body?.is_active !== false,
    },
  };
}

export function validateAliasPayload(body) {
  const fields = [];
  const push = (field, code) => fields.push({ field, code });

  if (!nonBlank(body?.merchant_id)) push('merchant_id', 'required');

  const kind = trimmed(body?.alias_kind) || 'name';
  if (!ALIAS_KINDS.includes(kind)) push('alias_kind', 'invalid_kind');

  const raw = trimmed(body?.alias_raw);
  if (!raw) {
    push('alias_raw', 'required');
  } else if (kind === 'name') {
    if (!approximateKey(raw)) {
      // Everything folded away — punctuation, an emoji, diacritics alone. The
      // database's non-empty CHECK would reject it, and every such input
      // produces the SAME empty key, so one stored row would match all of them.
      push('alias_raw', 'folds_to_empty');
    } else if (hasLookupNoise(raw)) {
      push('alias_raw', 'contains_lookup_noise');
    }
  } else if (kind === 'domain' && !HOST_RE.test(raw.toLowerCase())) {
    push('alias_raw', 'expected_bare_host');
  }

  const country = orNull(body?.country_code);
  if (country !== null && !ISO_COUNTRY_RE.test(country.toUpperCase())) {
    push('country_code', 'invalid_country');
  }

  const provenance = trimmed(body?.provenance) || 'admin';
  if (!ALIAS_PROVENANCE.includes(provenance)) push('provenance', 'invalid_provenance');

  const priority = body?.priority ?? 0;
  if (!Number.isInteger(priority)) push('priority', 'invalid_priority');

  if (fields.length > 0) return { ok: false, fields };

  return {
    ok: true,
    value: {
      merchant_id: trimmed(body.merchant_id),
      // Stored verbatim. alias_normalized is DERIVED by the database and can
      // never be supplied — PostgreSQL rejects an explicit value for a
      // GENERATED ALWAYS column outright.
      alias_raw: kind === 'domain' ? raw.toLowerCase() : raw,
      alias_kind: kind,
      country_code: country === null ? null : country.toUpperCase(),
      provenance,
      priority,
      // Reviewing is an explicit act. An alias created through this API is
      // unreviewed unless the caller says otherwise, so a bulk import can never
      // publish itself to devices.
      is_reviewed: body?.is_reviewed === true,
      is_active: body?.is_active !== false,
    },
  };
}
