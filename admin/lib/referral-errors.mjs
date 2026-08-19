// Referral & Ads Phase R2 — controlled mapping from database/RPC failures to
// safe Admin-facing messages. Mirrors coupon-errors.mjs: raw SQL text, the
// service-role details, constraint internals and stack traces NEVER reach the
// browser. The caller logs the raw error server-side and returns only what is
// here.
//
// The referral/entitlement admin RPCs (0083_referral_rewards.sql) raise typed
// errors via `RAISE EXCEPTION '<token>' USING ERRCODE = 'data_exception'`, so
// the token arrives as the PostgREST error `message`. We branch on that token
// (structural), not on free-text matching, wherever possible.

/** Stable machine codes the Admin UI can branch on, with human copy. */
export const REFERRAL_ERROR_MESSAGES = {
  // --- RPC-raised, typed (0083) ---------------------------------------------
  invalid_reason:
    'A reason is required: plain text, 4–500 characters, no control characters.',
  missing_operation_arguments:
    'This action is missing required information. Refresh and try again.',
  idempotency_mismatch:
    'This operation id was already used for a different action. Start the action again to get a new one.',
  invalid_event_type: 'That entitlement action is not one of grant, extend, shorten or revoke.',
  bad_entitlement_type: 'The only entitlement type in V1 is the ad-free report export.',
  referral_not_found: 'That referral no longer exists. Refresh and try again.',
  referral_not_rejectable:
    'Only a pending (attributed) referral can be rejected. This one has already progressed.',
  referral_not_reversible:
    'Only a qualified referral can be reversed. Reject a pending one instead.',
  progress_not_found: 'No referral progress exists for that user and reward type.',
  cycle_not_adjustable: 'That cycle cannot be adjusted (it is completed or awaiting a rule).',
  adjustment_crosses_milestone:
    'Progress cannot be moved across a completed milestone — a completed cycle’s grant stands.',
  no_active_rule: 'No active reward rule exists for that reward type.',
  no_active_referral_code: 'That user has no active referral code to rotate.',
  referral_code_generation_failed:
    'A new referral code could not be generated. Try again.',
  // --- validation (this module / referral-validation.mjs) -------------------
  required: 'This field is required.',
  invalid_operation_id: 'A valid operation id is required.',
  invalid_user_id: 'A valid user id is required.',
  invalid_referral_id: 'A valid referral id is required.',
  invalid_reward_type: 'Choose a valid reward type.',
  invalid_action: 'Choose a valid action.',
  invalid_required_referrals: 'Required referrals must be a whole number of at least 1.',
  invalid_reward_days: 'Reward days must be a whole number between 1 and 3650.',
  invalid_repeatable: 'Repeatable must be true or false.',
  invalid_effective_until: 'The effective-until time must be a valid date in the future.',
  duration_required: 'This action needs a positive number of days.',
  duration_not_allowed: 'A revoke action must not carry a duration.',
  invalid_duration_days: 'Duration must be a whole number between 1 and 3650.',
  invalid_qualified_in_cycle: 'The new progress value must be a whole number of at least 0.',
  invalid_query: 'Enter a user id, referral code, or email to search.',
  // --- generic --------------------------------------------------------------
  validation_failed: 'Some fields need attention.',
  duplicate_rule_version: 'A rule with that version already exists. Refresh and try again.',
  not_found: 'That record no longer exists. Refresh and try again.',
  unexpected: 'Something went wrong. The details were logged for the team.',
};

export function messageFor(code) {
  return REFERRAL_ERROR_MESSAGES[code] ?? REFERRAL_ERROR_MESSAGES.unexpected;
}

/** The exact set of typed tokens the 0083 admin RPCs raise. */
const RPC_TOKENS = new Set([
  'invalid_reason',
  'missing_operation_arguments',
  'idempotency_mismatch',
  'invalid_event_type',
  'bad_entitlement_type',
  'referral_not_found',
  'referral_not_rejectable',
  'referral_not_reversible',
  'progress_not_found',
  'cycle_not_adjustable',
  'adjustment_crosses_milestone',
  'no_active_rule',
  'no_active_referral_code',
  'referral_code_generation_failed',
]);

/**
 * Translate a PostgREST/Postgres error into a stable machine code. The referral
 * admin RPCs raise typed tokens as the error MESSAGE, so a token match wins
 * first; unique/check violations are handled by SQLSTATE as a backstop; anything
 * unrecognised becomes `unexpected`.
 *
 * @param {{ code?: string, message?: string, details?: string, hint?: string } | null} error
 * @returns {string} a key of REFERRAL_ERROR_MESSAGES
 */
export function mapDatabaseError(error) {
  if (!error) return 'unexpected';
  const code = String(error.code ?? '');
  const rawMessage = String(error.message ?? '');
  const text = `${rawMessage} ${error.details ?? ''} ${error.hint ?? ''}`;

  // 1) The RPC's own typed token (the common, authoritative path).
  const token = rawMessage.trim();
  if (RPC_TOKENS.has(token)) return token;
  for (const t of RPC_TOKENS) {
    if (text.includes(t)) return t;
  }

  // 2) SQLSTATE backstops for constraint hits that bypass the typed raises.
  if (code === '23505') {
    if (text.includes('referral_reward_rules') || text.includes('version')) {
      return 'duplicate_rule_version';
    }
    return 'unexpected';
  }
  if (code === '23514') {
    if (text.includes('reason')) return 'invalid_reason';
    if (text.includes('reward_type')) return 'invalid_reward_type';
    if (text.includes('required_referrals')) return 'invalid_required_referrals';
    if (text.includes('reward_days')) return 'invalid_reward_days';
    if (text.includes('window_order')) return 'invalid_effective_until';
    return 'unexpected';
  }
  // PostgREST: no row matched a single-object request.
  if (code === 'PGRST116') return 'not_found';
  return 'unexpected';
}

/**
 * Build the JSON body returned to the Admin browser. Intentionally minimal: a
 * stable code, human copy, and optional field-level codes. It never carries SQL,
 * constraint text, Supabase internals or a stack.
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
