import '../referrals/services/referral_service.dart';

/// The three-state client decision for the report-export ad-free entitlement
/// (docs REFERRAL_REWARDS_SYSTEM.md §22, REPORT_ADS §8). The client NEVER infers
/// entitlement from device time — the state comes from a fresh authoritative
/// server response (get_entitlement_decision), and ANY uncertainty resolves to
/// [unknownOrStale], never to "inactive".
enum ReportEntitlementState {
  /// Fresh server response: an active ad-free entitlement → NO AD.
  verifiedActive,

  /// Fresh server response: no active entitlement → eligible for one ad.
  verifiedInactive,

  /// Any lookup uncertainty (timeout, unreachable, signed-out, malformed,
  /// unconfigured, stale cache) → NO AD. Never treated as "not entitled".
  unknownOrStale,
}

/// Monotonic time source (ms). Robust against wall-clock jumps for TTL math.
final Stopwatch _monotonic = Stopwatch()..start();
int _defaultNowMs() => _monotonic.elapsedMilliseconds;

class _CacheEntry {
  const _CacheEntry({
    required this.userId,
    required this.state,
    required this.endsAt,
    required this.serverNow,
    required this.verifiedAtMs,
  });
  final String userId;
  final ReportEntitlementState state;
  final DateTime? endsAt;
  final DateTime? serverNow;
  final int verifiedAtMs;
}

/// Resolves and caches the report-export entitlement decision IN MEMORY only
/// (no Drift; Drift stays v31). The cache is keyed by the authenticated user id,
/// with a freshness TTL; a stale entry is never returned as a fresh decision,
/// and an entry for another user is never reused.
class ReportEntitlementResolver {
  ReportEntitlementResolver({
    required ReferralService service,
    required String? Function() currentUserId,
    Duration ttl = const Duration(minutes: 5),
    int Function()? nowMs,
  })  : _service = service,
        _currentUserId = currentUserId,
        _ttlMs = ttl.inMilliseconds,
        _nowMs = nowMs ?? _defaultNowMs;

  final ReferralService _service;
  final String? Function() _currentUserId;
  final int _ttlMs;
  final int Function() _nowMs;

  _CacheEntry? _cache;

  bool _isFresh(_CacheEntry e, String uid) =>
      e.userId == uid && (_nowMs() - e.verifiedAtMs) <= _ttlMs;

  /// Return a decision, using the fresh cache when available (no blocking
  /// network call on the export tap in that case). Signed-out → UNKNOWN.
  Future<ReportEntitlementState> resolve() async {
    final uid = _currentUserId();
    if (uid == null) {
      _cache = null;
      return ReportEntitlementState.unknownOrStale;
    }
    final c = _cache;
    if (c != null && _isFresh(c, uid)) return c.state;
    return _fetchAndCache(uid);
  }

  /// Force a fresh lookup (sign-in / resume / report-area entry). Best-effort:
  /// a failure leaves the state UNKNOWN and does not surface an error.
  Future<ReportEntitlementState> refresh() async {
    final uid = _currentUserId();
    if (uid == null) {
      _cache = null;
      return ReportEntitlementState.unknownOrStale;
    }
    return _fetchAndCache(uid);
  }

  Future<ReportEntitlementState> _fetchAndCache(String uid) async {
    try {
      final decision = await _service.getEntitlementDecision();
      if (decision == null) {
        // Unconfigured / no authoritative answer → UNKNOWN; do not cache fresh.
        return ReportEntitlementState.unknownOrStale;
      }
      final state = decision.active
          ? ReportEntitlementState.verifiedActive
          : ReportEntitlementState.verifiedInactive;
      _cache = _CacheEntry(
        userId: uid,
        state: state,
        endsAt: decision.endsAt,
        serverNow: decision.serverNow,
        verifiedAtMs: _nowMs(),
      );
      return state;
    } catch (_) {
      // Lookup uncertainty → UNKNOWN, never "not entitled". Leave any stale
      // entry untouched; it will not be returned as fresh anyway.
      return ReportEntitlementState.unknownOrStale;
    }
  }

  /// Clear immediately on logout / account switch / deletion / identity change.
  void clear() => _cache = null;

  /// The cached ad-free expiry, for the subtle "ad-free until …" status (§23).
  DateTime? get cachedEndsAt => _cache?.endsAt;
}
