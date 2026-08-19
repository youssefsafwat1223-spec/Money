// Referral feature (Phase R3) — immutable DTOs decoded from the server-authoritative
// referral RPCs in 0083_referral_rewards.sql. The client NEVER computes progress
// or entitlement; it only presents what the server returns (docs
// REFERRAL_REWARDS_SYSTEM.md §22/§32). No local persistence — Drift stays v31.

/// Canonical server reason/status tokens. Kept as constants so the UI mapping
/// and tests reference one source, and so no raw token is ever shown verbatim.
class ReferralReason {
  ReferralReason._();

  // apply_referral_code soft failures (jsonb {ok:false, reason:...})
  static const invalidCode = 'invalid_code';
  static const selfReferral = 'self_referral';
  static const alreadyReferred = 'already_referred';
  static const noActiveRule = 'no_active_rule';

  // qualify_referral_internal reasons (jsonb {qualified:false, reason:...})
  static const noAttribution = 'no_attribution';
  static const identityUnverified = 'identity_unverified';
  static const awaitingActiveRule = 'awaiting_active_rule';
  static const cycleCompleted = 'cycle_completed';
}

/// Attribution status of the caller's OWN referral row (never a counterpart id).
enum AttributionStatus { none, attributed, qualified, rejected, reversed, unknown }

AttributionStatus attributionStatusFrom(String? raw) {
  switch (raw) {
    case 'attributed':
      return AttributionStatus.attributed;
    case 'qualified':
      return AttributionStatus.qualified;
    case 'rejected':
      return AttributionStatus.rejected;
    case 'reversed':
      return AttributionStatus.reversed;
    case 'none':
      return AttributionStatus.none;
    default:
      return AttributionStatus.unknown;
  }
}

/// Server-authoritative referral summary (get_referral_summary). Rule fields are
/// nullable because a user may have no pinned rule and no active rule yet.
class ReferralSummary {
  const ReferralSummary({
    required this.referralCode,
    required this.progress,
    required this.requiredReferrals,
    required this.rewardDays,
    required this.repeatable,
    required this.cycleIndex,
    required this.cycleState,
    required this.referralsAvailable,
    required this.attributionStatus,
    required this.entitlementStatus,
    required this.entitlementEndsAt,
    required this.serverNow,
  });

  final String referralCode;
  final int progress; // qualified_in_cycle, server-owned
  final int? requiredReferrals;
  final int? rewardDays;
  final bool? repeatable;
  final int cycleIndex;
  final String cycleState; // open | completed | awaiting_rule
  final bool referralsAvailable; // an active rule exists server-side
  final AttributionStatus attributionStatus;
  final String entitlementStatus; // none | active | revoked
  final DateTime? entitlementEndsAt;
  final DateTime? serverNow;

  /// "Currently entitled" is a SERVER decision (status=active AND ends_at>now),
  /// evaluated against the server's own clock — never inferred from device time.
  bool get entitlementActive =>
      entitlementStatus == 'active' &&
      entitlementEndsAt != null &&
      serverNow != null &&
      entitlementEndsAt!.isAfter(serverNow!);

  static DateTime? _parseTs(Object? v) =>
      v is String ? DateTime.tryParse(v)?.toUtc() : null;

  static int? _asInt(Object? v) => v is num ? v.toInt() : null;

  factory ReferralSummary.fromJson(Map<String, dynamic> json) {
    return ReferralSummary(
      referralCode: (json['referral_code'] as String?) ?? '',
      progress: _asInt(json['progress']) ?? 0,
      requiredReferrals: _asInt(json['required_referrals']),
      rewardDays: _asInt(json['reward_days']),
      repeatable: json['repeatable'] as bool?,
      cycleIndex: _asInt(json['cycle_index']) ?? 1,
      cycleState: (json['cycle_state'] as String?) ?? 'open',
      referralsAvailable: json['referrals_available'] as bool? ?? false,
      attributionStatus: attributionStatusFrom(json['attribution_status'] as String?),
      entitlementStatus: (json['entitlement_status'] as String?) ?? 'none',
      entitlementEndsAt: _parseTs(json['entitlement_ends_at']),
      serverNow: _parseTs(json['server_now']),
    );
  }
}

/// Result of a qualification attempt embedded in apply/request responses.
class QualificationOutcome {
  const QualificationOutcome({
    required this.qualified,
    required this.granted,
    this.reason,
    this.progress,
    this.required,
  });

  final bool qualified;
  final bool granted; // a milestone reward was issued on this call
  final String? reason; // set when qualified == false
  final int? progress; // server progress after this attempt
  final int? required;

  factory QualificationOutcome.fromJson(Map<String, dynamic> json) {
    return QualificationOutcome(
      qualified: json['qualified'] as bool? ?? false,
      granted: json['granted'] as bool? ?? false,
      reason: json['reason'] as String?,
      progress: json['progress'] is num ? (json['progress'] as num).toInt() : null,
      required: json['required'] is num ? (json['required'] as num).toInt() : null,
    );
  }
}

/// Result of apply_referral_code. A soft failure carries a [reason]; a success
/// carries the inline [qualification] attempt.
class ApplyCodeOutcome {
  const ApplyCodeOutcome({
    required this.ok,
    this.reason,
    this.qualification,
  });

  final bool ok;
  final String? reason;
  final QualificationOutcome? qualification;

  factory ApplyCodeOutcome.fromJson(Map<String, dynamic> json) {
    final q = json['qualification'];
    return ApplyCodeOutcome(
      ok: json['ok'] as bool? ?? false,
      reason: json['reason'] as String?,
      qualification: q is Map
          ? QualificationOutcome.fromJson(Map<String, dynamic>.from(q))
          : null,
    );
  }
}

/// The Report gate's server contract (get_entitlement_decision). A failure to
/// obtain this is UNKNOWN, never a decision — that logic lives in a later phase;
/// here it only surfaces the ad-free status/expiry for display.
class EntitlementDecision {
  const EntitlementDecision({
    required this.entitlementType,
    required this.status,
    required this.active,
    required this.endsAt,
    required this.serverNow,
  });

  final String entitlementType;
  final String status; // none | active | revoked
  final bool active; // server-computed: status=active AND ends_at>now
  final DateTime? endsAt;
  final DateTime? serverNow;

  factory EntitlementDecision.fromJson(Map<String, dynamic> json) {
    return EntitlementDecision(
      entitlementType: (json['entitlement_type'] as String?) ?? '',
      status: (json['status'] as String?) ?? 'none',
      active: json['active'] as bool? ?? false,
      endsAt: ReferralSummary._parseTs(json['ends_at']),
      serverNow: ReferralSummary._parseTs(json['server_now']),
    );
  }
}
