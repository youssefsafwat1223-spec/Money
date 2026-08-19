// Referral & Ads Phase R2 — the ONE authoritative server-side validation schema
// for the Referral/Entitlement Admin API. The TypeScript routes and the
// node:test suite share exactly this code (tsconfig allowJs) so there is no
// second, drifting schema. The server is always the authority; the database
// CHECKs and the SECURITY DEFINER RPCs in 0083_referral_rewards.sql are the
// final line. These validators exist to return a controlled 4xx BEFORE a DB
// round-trip and to mirror the DB contracts (defence in depth) — they never
// replace them.

const isString = (v) => typeof v === 'string';
const trimmed = (v) => (isString(v) ? v.trim() : '');
const nonBlank = (v) => trimmed(v).length > 0;

/** RFC-4122 UUID (any version), case-insensitive. crypto.randomUUID() matches. */
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function isUuid(value) {
  return isString(value) && UUID_RE.test(value.trim());
}

// --- reason contract (spec §7.2; mirrors 0083 referral_norm_reason +
//     referral_admin_require_reason) ------------------------------------------
export const REASON_MIN = 4;
export const REASON_MAX = 500;
/** Non-whitespace control characters (mirrors the 0083 audit CHECK regex). */
const CONTROL_CHAR_RE = /[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/;

/**
 * Normalize + validate a manual-action reason. Collapses whitespace runs to a
 * single space and trims (as the DB does), then enforces plain-text 4–500 with
 * no control characters.
 *
 * @returns {{ ok: true, value: string } | { ok: false, error: 'invalid_reason' }}
 */
export function validateReason(input) {
  if (!isString(input)) return { ok: false, error: 'invalid_reason' };
  const value = input.replace(/\s+/g, ' ').trim();
  if (
    value.length < REASON_MIN ||
    value.length > REASON_MAX ||
    CONTROL_CHAR_RE.test(value)
  ) {
    return { ok: false, error: 'invalid_reason' };
  }
  return { ok: true, value };
}

// --- audit before/after allowlist (spec §9.2; mirrors 0083
//     referral_audit_allowlist) — the ONLY keys that may ever appear ----------
export const AUDIT_ALLOWLIST = [
  'entitlement_type',
  'status',
  'ends_at',
  'duration_days',
  'rule_id',
  'rule_version',
  'required_referrals',
  'reward_days',
  'repeatable',
  'is_active',
  'cycle_index',
  'qualified_in_cycle',
  'referral_status',
  'rejection_reason',
];
const AUDIT_ALLOWLIST_SET = new Set(AUDIT_ALLOWLIST);

/**
 * Drop every non-allowlisted key from an audit snapshot. Mirrors the server-side
 * referral_audit_allowlist() so a UI or route can never surface a
 * non-allowlisted key even before the DB strips it. Null passes through.
 */
export function filterAuditPayload(payload) {
  if (payload === null || payload === undefined) return null;
  if (typeof payload !== 'object' || Array.isArray(payload)) return {};
  const out = {};
  for (const [k, v] of Object.entries(payload)) {
    if (AUDIT_ALLOWLIST_SET.has(k)) out[k] = v;
  }
  return out;
}

// --- reward rule config (spec §4; mirrors referral_reward_rules CHECKs) ------
export const REWARD_TYPES = ['report_export_ad_free'];
/** "sane max" (spec §4) — an Admin guard; the DB CHECK is only `> 0`. */
export const REWARD_DAYS_MAX = 3650;

export function isRewardType(value) {
  return isString(value) && REWARD_TYPES.includes(value);
}

function isPositiveInt(v, max) {
  const n = Number(v);
  return Number.isInteger(n) && n >= 1 && (max === undefined || n <= max);
}

/**
 * Validate an `admin_publish_reward_rule` payload (creating a new rule version).
 *
 * @returns {{ ok: true, value: Record<string, unknown> } |
 *           { ok: false, errors: Array<{ field: string, error: string }> }}
 */
export function validateRulePayload(input) {
  const errors = [];
  const fail = (field, error) => errors.push({ field, error });
  const body = input && typeof input === 'object' ? input : {};

  if (!isUuid(body.operation_id)) fail('operation_id', 'invalid_operation_id');
  if (!isRewardType(body.reward_type)) fail('reward_type', 'invalid_reward_type');
  if (!isPositiveInt(body.required_referrals)) {
    fail('required_referrals', 'invalid_required_referrals');
  }
  if (!isPositiveInt(body.reward_days, REWARD_DAYS_MAX)) {
    fail('reward_days', 'invalid_reward_days');
  }
  if (typeof body.repeatable !== 'boolean') fail('repeatable', 'invalid_repeatable');

  let effectiveUntil = null;
  if (nonBlank(body.effective_until)) {
    effectiveUntil = parseTimestamp(body.effective_until);
    if (!effectiveUntil || new Date(effectiveUntil).getTime() <= Date.now()) {
      fail('effective_until', 'invalid_effective_until');
    }
  }

  const reason = validateReason(body.reason);
  if (!reason.ok) fail('reason', 'invalid_reason');

  if (errors.length > 0) return { ok: false, errors };
  return {
    ok: true,
    value: {
      operation_id: body.operation_id.trim(),
      reward_type: body.reward_type,
      required_referrals: Number(body.required_referrals),
      reward_days: Number(body.reward_days),
      repeatable: body.repeatable,
      effective_until: effectiveUntil,
      reason: reason.value,
    },
  };
}

// --- entitlement manual action (spec §7; admin_mutate_entitlement) -----------
export const ENTITLEMENT_ACTIONS = ['grant', 'extend', 'shorten', 'revoke'];
/** Actions that require a positive duration; `revoke` must NOT carry one. */
const DURATION_ACTIONS = new Set(['grant', 'extend', 'shorten']);

/**
 * Validate a manual entitlement action. `operation_id` is minted once per
 * operator intent in the UI and passed through unchanged; the DB enforces
 * idempotency, this only rejects a structurally-bad request early.
 *
 * @returns {{ ok: true, value: Record<string, unknown> } |
 *           { ok: false, errors: Array<{ field: string, error: string }> }}
 */
export function validateEntitlementAction(input) {
  const errors = [];
  const fail = (field, error) => errors.push({ field, error });
  const body = input && typeof input === 'object' ? input : {};

  if (!isUuid(body.operation_id)) fail('operation_id', 'invalid_operation_id');
  if (!isUuid(body.user_id)) fail('user_id', 'invalid_user_id');

  const action = body.action;
  if (!ENTITLEMENT_ACTIONS.includes(action)) fail('action', 'invalid_action');

  const entitlementType =
    body.entitlement_type === undefined ? 'report_export_ad_free' : body.entitlement_type;
  if (!isRewardType(entitlementType)) fail('entitlement_type', 'invalid_reward_type');

  let durationDays = null;
  if (DURATION_ACTIONS.has(action)) {
    if (body.duration_days === undefined || body.duration_days === null) {
      fail('duration_days', 'duration_required');
    } else if (!isPositiveInt(body.duration_days, REWARD_DAYS_MAX)) {
      fail('duration_days', 'invalid_duration_days');
    } else {
      durationDays = Number(body.duration_days);
    }
  } else if (action === 'revoke') {
    if (body.duration_days !== undefined && body.duration_days !== null) {
      fail('duration_days', 'duration_not_allowed');
    }
  }

  const reason = validateReason(body.reason);
  if (!reason.ok) fail('reason', 'invalid_reason');

  if (errors.length > 0) return { ok: false, errors };
  return {
    ok: true,
    value: {
      operation_id: body.operation_id.trim(),
      user_id: body.user_id.trim(),
      action,
      entitlement_type: entitlementType,
      duration_days: durationDays,
      reason: reason.value,
    },
  };
}

// --- referral reject / reverse (admin_reject_referral / admin_reverse_referral)
/**
 * Shared shape for reject/reverse: operation_id, referral_id, reason.
 * @returns {{ ok: true, value: Record<string, unknown> } | { ok: false, errors: Array }}
 */
export function validateReferralAction(input) {
  const errors = [];
  const fail = (field, error) => errors.push({ field, error });
  const body = input && typeof input === 'object' ? input : {};

  if (!isUuid(body.operation_id)) fail('operation_id', 'invalid_operation_id');
  if (!isUuid(body.referral_id)) fail('referral_id', 'invalid_referral_id');
  const reason = validateReason(body.reason);
  if (!reason.ok) fail('reason', 'invalid_reason');

  if (errors.length > 0) return { ok: false, errors };
  return {
    ok: true,
    value: {
      operation_id: body.operation_id.trim(),
      referral_id: body.referral_id.trim(),
      reason: reason.value,
    },
  };
}

// --- progress adjust (admin_adjust_referral_progress) ------------------------
/**
 * @returns {{ ok: true, value: Record<string, unknown> } | { ok: false, errors: Array }}
 */
export function validateProgressAdjust(input) {
  const errors = [];
  const fail = (field, error) => errors.push({ field, error });
  const body = input && typeof input === 'object' ? input : {};

  if (!isUuid(body.operation_id)) fail('operation_id', 'invalid_operation_id');
  if (!isUuid(body.referrer_user_id)) fail('referrer_user_id', 'invalid_user_id');
  if (!isRewardType(body.reward_type)) fail('reward_type', 'invalid_reward_type');
  const q = Number(body.qualified_in_cycle);
  if (!Number.isInteger(q) || q < 0) fail('qualified_in_cycle', 'invalid_qualified_in_cycle');
  const reason = validateReason(body.reason);
  if (!reason.ok) fail('reason', 'invalid_reason');

  if (errors.length > 0) return { ok: false, errors };
  return {
    ok: true,
    value: {
      operation_id: body.operation_id.trim(),
      referrer_user_id: body.referrer_user_id.trim(),
      reward_type: body.reward_type,
      qualified_in_cycle: q,
      reason: reason.value,
    },
  };
}

// --- rotate code (admin_rotate_referral_code) --------------------------------
/**
 * @returns {{ ok: true, value: Record<string, unknown> } | { ok: false, errors: Array }}
 */
export function validateRotateCode(input) {
  const errors = [];
  const fail = (field, error) => errors.push({ field, error });
  const body = input && typeof input === 'object' ? input : {};

  if (!isUuid(body.operation_id)) fail('operation_id', 'invalid_operation_id');
  if (!isUuid(body.user_id)) fail('user_id', 'invalid_user_id');
  const reason = validateReason(body.reason);
  if (!reason.ok) fail('reason', 'invalid_reason');

  if (errors.length > 0) return { ok: false, errors };
  return {
    ok: true,
    value: {
      operation_id: body.operation_id.trim(),
      user_id: body.user_id.trim(),
      reason: reason.value,
    },
  };
}

// --- deactivate rule (admin_deactivate_reward_rule) --------------------------
/**
 * @returns {{ ok: true, value: Record<string, unknown> } | { ok: false, errors: Array }}
 */
export function validateDeactivateRule(input) {
  const errors = [];
  const fail = (field, error) => errors.push({ field, error });
  const body = input && typeof input === 'object' ? input : {};

  if (!isUuid(body.operation_id)) fail('operation_id', 'invalid_operation_id');
  if (!isRewardType(body.reward_type)) fail('reward_type', 'invalid_reward_type');
  const reason = validateReason(body.reason);
  if (!reason.ok) fail('reason', 'invalid_reason');

  if (errors.length > 0) return { ok: false, errors };
  return {
    ok: true,
    value: {
      operation_id: body.operation_id.trim(),
      reward_type: body.reward_type,
      reason: reason.value,
    },
  };
}

// --- user lookup query (spec §5 — safe identifiers only) ---------------------
/**
 * Classify a lookup query into user_id | code | email; no financial fields.
 * @returns {{ ok: true, kind: 'user_id' | 'code' | 'email', value: string } |
 *           { ok: false, error: 'invalid_query' }}
 */
export function classifyLookupQuery(input) {
  const q = trimmed(input);
  if (!q) return { ok: false, error: 'invalid_query' };
  if (isUuid(q)) return { ok: true, kind: 'user_id', value: q };
  if (q.includes('@')) return { ok: true, kind: 'email', value: q.toLowerCase() };
  // Referral codes are Crockford base32 (8 chars) but Admin lookup is lenient:
  // normalize to uppercase and treat any remaining token as a code candidate.
  return { ok: true, kind: 'code', value: q.toUpperCase() };
}

/** Parse an ISO-ish timestamp to a canonical ISO string, or null. */
export function parseTimestamp(value) {
  if (!isString(value) || value.trim() === '') return null;
  const d = new Date(value);
  if (Number.isNaN(d.getTime())) return null;
  return d.toISOString();
}
