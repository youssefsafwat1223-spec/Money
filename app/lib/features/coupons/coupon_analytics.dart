import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/backend/supabase_config.dart';
import '../../domain/entities/supporting_entities.dart';

/// MALI-COUPONS (Phase C4) — the four V1 coupon analytics events.
///
/// These are PRODUCT / DIRECTIONAL analytics, never billing-grade redemption or
/// conversion accounting: migration 0082 stores only `(day, coupon_id, event)`
/// with no user, install or device identifier, so repeats are unattributable by
/// design. `cta_click` counts a CLICK, not a redemption — the merchant side is
/// never observed.
enum CouponAnalyticsEvent {
  impression('impression'),
  detailView('detail_view'),
  codeCopy('code_copy'),
  ctaClick('cta_click');

  const CouponAnalyticsEvent(this.wireName);

  /// The exact value accepted by `record_coupon_event` (0082 CHECK).
  final String wireName;
}

/// Sends coupon interaction events to `record_coupon_event`.
///
/// Contract:
///   * CONSENT-GATED — nothing is sent unless the user's cloud consent is
///     accepted (fail-closed while unset), Supabase is configured, and a
///     session exists. Browsing and redeeming always work regardless.
///   * FIRE AND FORGET — every send swallows its own failure so an unawaited
///     call can never surface an unhandled async error, and analytics can never
///     block or fail a copy/launch.
///   * PRIVACY — the payload is exactly `{p_coupon_id, p_event}`. No spend
///     totals, categories, country, install id or financial data are ever
///     attached (locked by an architecture test).
///   * SESSION DEDUP — `impression` and `detail_view` are claimed at most once
///     per coupon per app process. The claim lives here (a process-lifetime
///     singleton), NOT in widget state, so rebuilds, scroll re-entry and tab
///     switches cannot double-count. Nothing is persisted: a new process may
///     count again. Explicit actions (`code_copy`, `cta_click`) are never
///     deduped — a deliberate repeat is a real repeat.
class CouponAnalyticsClient {
  CouponAnalyticsClient({
    required Future<UserSettingsEntity> Function() loadSettings,
    SupabaseClient? client,
    bool Function(SupabaseClient client)? hasSession,
  })  : _loadSettings = loadSettings,
        _client = client,
        _hasSession = hasSession ?? _defaultHasSession;

  /// Production gate: never send anything without an authenticated session
  /// (the RPC is granted to `authenticated` only). Injectable so the consent /
  /// dedup contract is testable without a real Supabase session.
  static bool _defaultHasSession(SupabaseClient client) =>
      client.auth.currentUser != null;

  final Future<UserSettingsEntity> Function() _loadSettings;
  final SupabaseClient? _client;
  final bool Function(SupabaseClient client) _hasSession;

  final Set<String> _impressionClaimed = <String>{};
  final Set<String> _detailViewClaimed = <String>{};

  /// Visible-for-testing view of the session dedup state.
  @visibleForTesting
  int get claimedImpressionCount => _impressionClaimed.length;

  /// Records a first meaningful view of a coupon card (once per session).
  Future<void> recordImpression(String couponId) async {
    if (!_impressionClaimed.add(couponId)) return;
    await _send(couponId, CouponAnalyticsEvent.impression);
  }

  /// Records the first time the detail sheet is opened (once per session).
  Future<void> recordDetailView(String couponId) async {
    if (!_detailViewClaimed.add(couponId)) return;
    await _send(couponId, CouponAnalyticsEvent.detailView);
  }

  /// Records an explicit copy. Deliberate repeats each count.
  Future<void> recordCodeCopy(String couponId) =>
      _send(couponId, CouponAnalyticsEvent.codeCopy);

  /// Records an explicit CTA press. Deliberate repeats each count.
  Future<void> recordCtaClick(String couponId) =>
      _send(couponId, CouponAnalyticsEvent.ctaClick);

  Future<void> _send(String couponId, CouponAnalyticsEvent event) async {
    try {
      if (_client == null && !SupabaseConfig.isConfigured) return;
      final client = _client ?? Supabase.instance.client;
      if (!_hasSession(client)) return;

      // Consent is read FRESH on every send: a user may revoke it at any time,
      // and a value cached at construction would keep sending afterwards.
      final settings = await _loadSettings();
      if (!settings.cloudProcessingEnabled) return;

      await client.rpc<void>(
        'record_coupon_event',
        params: {'p_coupon_id': couponId, 'p_event': event.wireName},
      );
    } catch (error) {
      // Analytics are best-effort: never retried, never queued in an outbox,
      // and never allowed to break the interaction the user just performed.
      if (kDebugMode) {
        debugPrint('[CouponAnalytics] skipped: ${error.runtimeType}');
      }
    }
  }
}
