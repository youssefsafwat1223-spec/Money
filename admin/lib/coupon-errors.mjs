// Coupons Phase C3 — controlled mapping from database/storage failures to safe
// Admin-facing messages. Raw SQL text, constraint internals, service-role
// details and stack traces NEVER reach the browser; the caller logs the raw
// error server-side and returns only what is here.

/** Stable machine codes the Admin UI can branch on, with human copy. */
export const COUPON_ERROR_MESSAGES = {
  duplicate_slug: 'That slug is already used by another offer. Choose a different one.',
  duplicate_tag_key: 'A tag with that key already exists. Pick the existing tag instead.',
  unknown_category: 'That display category does not exist. Refresh and pick another.',
  category_in_use:
    'This category is currently used by active offers. Disable or move those offers first.',
  invalid_redemption_shape:
    'The redemption details are inconsistent: a code offer needs a code, and a link offer needs an https destination and no code.',
  invalid_dates: 'The validity window is invalid: the end must be after the start.',
  invalid_country_code: 'Country targeting must use uppercase ISO-3166-1 alpha-2 codes.',
  invalid_url: 'The destination must be a valid https:// URL.',
  url_not_https: 'The destination must use https://.',
  url_has_credentials: 'The destination must not embed a username or password.',
  url_private_host: 'The destination must be a public host.',
  invalid_slug: 'The slug must be lowercase letters, digits, hyphen or underscore.',
  invalid_category: 'Choose a valid display category.',
  invalid_tag_key: 'The tag key must be 2–32 characters (letters, digits or underscore).',
  invalid_priority: 'Priority must be a whole number between -1000 and 1000.',
  invalid_hex: 'The accent colour must look like #RRGGBB.',
  code_required: 'A code offer needs a coupon code.',
  code_not_allowed_for_link: 'A link offer must not carry a coupon code.',
  countries_required_when_not_global:
    'Pick at least one country, or switch the offer to globally available.',
  window_ends_before_start: 'The end of the validity window must be after its start.',
  image_empty: 'The image file is empty.',
  image_too_large: 'The image must be 512 KB or smaller.',
  image_mime_not_allowed: 'Only WebP, PNG and JPEG images are accepted.',
  image_signature_unknown: 'That file is not a supported image.',
  image_signature_mismatch: 'The file contents do not match its declared image type.',
  image_unreadable: 'The image could not be read.',
  storage_failed: 'The image could not be stored. Try again.',
  required: 'This field is required.',
  invalid_date: 'Enter a valid date and time.',
  invalid_redemption_type: 'Choose either a code or a link offer.',
  invalid_sort_order: 'Sort order must be a whole number.',
  invalid_category_key: 'The category key must be 2–32 lowercase letters, digits or underscore.',
  not_found: 'That record no longer exists. Refresh and try again.',
  unexpected: 'Something went wrong. The details were logged for the team.',
};

export function messageFor(code) {
  return COUPON_ERROR_MESSAGES[code] ?? COUPON_ERROR_MESSAGES.unexpected;
}

/**
 * Translate a PostgREST/Postgres error into a stable machine code, using the
 * constraint NAME (structural) rather than free-text message matching wherever
 * possible. Anything unrecognised becomes `unexpected`.
 *
 * @param {{ code?: string, message?: string, details?: string } | null} error
 * @returns {string} a key of COUPON_ERROR_MESSAGES
 */
export function mapDatabaseError(error) {
  if (!error) return 'unexpected';
  const code = String(error.code ?? '');
  const text = `${error.message ?? ''} ${error.details ?? ''}`;

  // 23505 unique_violation — which unique index?
  if (code === '23505') {
    if (text.includes('coupons_slug_key') || text.includes('slug')) return 'duplicate_slug';
    if (text.includes('coupon_tags_key_key') || text.includes('key')) return 'duplicate_tag_key';
    return 'unexpected';
  }
  // 23503 foreign_key_violation — the display category is the only client-set FK.
  if (code === '23503') return 'unknown_category';
  // 23001 restrict_violation — the 0081 category-deactivation guard.
  if (code === '23001') return 'category_in_use';
  // 23514 check_violation — identify by constraint name.
  if (code === '23514') {
    if (text.includes('coupons_redemption_shape') || text.includes('coupons_code_shape')) {
      return 'invalid_redemption_shape';
    }
    if (text.includes('coupons_url_https')) return 'url_not_https';
    if (text.includes('coupons_country_codes_shape')) return 'invalid_country_code';
    if (text.includes('coupons_window_order')) return 'invalid_dates';
    if (text.includes('coupons_accent_hex_shape')) return 'invalid_hex';
    if (text.includes('coupons_slug_shape')) return 'invalid_slug';
    if (text.includes('coupon_tags_key_shape')) return 'invalid_tag_key';
    if (text.includes('coupon_categories_key_shape')) return 'invalid_category_key';
    return 'unexpected';
  }
  // The category-deactivation trigger raises with this ERRCODE via RAISE.
  if (text.includes('cannot deactivate')) return 'category_in_use';
  // PostgREST: no row matched a single-object request.
  if (code === 'PGRST116') return 'not_found';
  return 'unexpected';
}

/**
 * Build the JSON body returned to the Admin browser. It is intentionally
 * minimal: a stable code, human copy, and optional field-level codes. It never
 * carries SQL, constraint text, Supabase internals or a stack.
 */
export function safeErrorBody(code, fields) {
  return {
    error: code,
    message: messageFor(code),
    ...(Array.isArray(fields) && fields.length
      ? { fields: fields.map((f) => ({ field: f.field, error: f.error, message: messageFor(f.error) })) }
      : {}),
  };
}
