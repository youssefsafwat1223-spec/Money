import 'dart:async';

import '../../core/backend/metrics_client.dart';

/// Operational telemetry for the banner placement.
///
/// The same shape as the report-export analytics: consent-gated on
/// `cloudProcessingEnabled` read FRESH on every send, fire-and-forget, failures
/// swallowed, and a KEY plus a placement dimension — nothing else.
///
/// What is deliberately never attached: amount, currency, merchant, bank,
/// category, SMS content, account, or any spending signal. Qirsh does not build
/// ad targeting out of a user's bank messages, and the way to make that true is
/// for the financial types to be unreachable from here — this file imports one
/// thing, and an architecture test asserts the ads layer imports nothing from
/// `domain/`, `engine/` or `data/`.
class BannerAdsAnalytics {
  BannerAdsAnalytics({
    required Future<bool> Function() cloudProcessingEnabled,
    required MetricsClient metrics,
  })  : _cloudProcessingEnabled = cloudProcessingEnabled,
        _metrics = metrics;

  final Future<bool> Function() _cloudProcessingEnabled;
  final MetricsClient _metrics;

  /// The complete set of keys this class can ever emit. Mirrored by the
  /// server-side allowlist in migration 0098 (DEFERRED — `supabase/deferred/`,
  /// so these keys are dropped server-side until an owner activates it) — a key
  /// that is not in both is a
  /// silently dropped row, which is worse than no telemetry because it looks
  /// like it works.
  static const Set<String> eventKeys = {
    'banner_ad_requested',
    'banner_ad_loaded',
    'banner_ad_failed',
    'banner_ad_impression',
  };

  void record(String event, String placementKey) {
    if (!eventKeys.contains(event)) return;
    unawaited(_emit(event, placementKey));
  }

  Future<void> _emit(String event, String placementKey) async {
    try {
      if (!await _cloudProcessingEnabled()) return;
      await _metrics.logEvent(event, dimension: placementKey);
    } catch (_) {
      // Best-effort. Telemetry never affects an ad and never affects the app.
    }
  }
}
