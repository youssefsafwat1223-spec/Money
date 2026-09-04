import 'dart:async';

import '../../core/backend/metrics_client.dart';

/// Optional Qirsh product-analytics for the report-export ad flow (§24). Every
/// event is:
///   * consent-gated — read cloudProcessingEnabled FRESH on each send;
///   * fire-and-forget — never awaited by the caller, never blocks ad / export /
///     report generation;
///   * best-effort — failures are swallowed.
/// AdMob remains the authority for ad impressions/revenue. There is NO reward
/// event (this is standard interstitial monetization, not rewarded).
///
/// The sink is the generic consent-neutral `record_metric` RPC via MetricsClient.
/// Unrecognised keys are silent server-side no-ops; these keys were dropped that
/// way from R4 until migration `0098` finally allowlisted them, alongside the
/// banner keys. 0098 is **DEFERRED** (`supabase/deferred/`, 2026-09-04): it
/// would enable this telemetry for every cloud-consenting user and there is no
/// telemetry feature flag to stop it, so activation is an owner decision.
/// Until it is applied these events are still dropped server-side — an events
/// pipeline that looks wired and records nothing is worse than none, because
/// nobody re-checks a feature they believe is working.
class ReportAdsAnalytics {
  ReportAdsAnalytics({
    required Future<bool> Function() cloudProcessingEnabled,
    required MetricsClient metrics,
  })  : _cloudProcessingEnabled = cloudProcessingEnabled,
        _metrics = metrics;

  /// Read FRESH on each send — a user may revoke consent at any time.
  final Future<bool> Function() _cloudProcessingEnabled;
  final MetricsClient _metrics;

  void exportRequested() => _fire('report_export_requested');
  void adLoadRequested() => _fire('report_ad_load_requested');
  void adImpression() => _fire('report_ad_impression');
  void adDismissed() => _fire('report_ad_dismissed');
  void adLoadFailed() => _fire('report_ad_load_failed');
  void adShowFailed() => _fire('report_ad_show_failed');
  void exportCompleted() => _fire('report_export_completed');

  void _fire(String key) => unawaited(_emit(key));

  Future<void> _emit(String key) async {
    try {
      if (!await _cloudProcessingEnabled()) return; // consent gate (§12/§24)
      await _metrics.logEvent(key);
    } catch (_) {
      // best-effort — never propagate
    }
  }
}
