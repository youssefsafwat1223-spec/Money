import 'dart:async';

import 'ad_consent_service.dart';
import 'report_ads_analytics.dart';
import 'report_export_ad_gateway.dart';
import 'report_entitlement.dart';

/// The report-export attempt lifecycle (§19). The coordinator owns
/// idle→resolvingEntitlement→preparingAd→presentingAd→generating→completed;
/// `sharing` happens downstream in the preview screen.
enum ReportExportPhase {
  idle,
  resolvingEntitlement,
  preparingAd,
  presentingAd,
  generating,
  sharing,
  completed,
}

/// Wraps the existing report-export choke point with a narrow state machine
/// (R4). It owns NO report logic — `generate` (the caller's closure around the
/// report-export choke point) is invoked EXACTLY ONCE per accepted attempt.
///
/// Invariants:
///  * FAIL-OPEN — every terminal ad outcome proceeds to generation (§4).
///  * SINGLE-FLIGHT — one accepted tap ⇒ ≤ one ad opportunity and ≤ one
///    generation; repeated taps while active are ignored (§5).
///  * exportAttemptId — each attempt is tagged; stale continuations bail (§5/§20).
///  * NEVER HANGS — the gateway/consent futures always complete (§20).
class ReportExportCoordinator {
  ReportExportCoordinator({
    required bool Function() reportAdsEnabled,
    required bool Function() adConfigAvailable,
    required ReportEntitlementResolver entitlement,
    required AdConsentService consent,
    required ReportExportAdGateway gateway,
    required ReportAdsAnalytics analytics,
    String Function()? mintAttemptId,
  })  : _reportAdsEnabled = reportAdsEnabled,
        _adConfigAvailable = adConfigAvailable,
        _entitlement = entitlement,
        _consent = consent,
        _gateway = gateway,
        _analytics = analytics,
        _mintAttemptId = mintAttemptId ?? _defaultMintAttemptId;

  final bool Function() _reportAdsEnabled;
  final bool Function() _adConfigAvailable;
  final ReportEntitlementResolver _entitlement;
  final AdConsentService _consent;
  final ReportExportAdGateway _gateway;
  final ReportAdsAnalytics _analytics;
  final String Function() _mintAttemptId;

  static int _seq = 0;
  static String _defaultMintAttemptId() => 'export-${_seq++}';

  ReportExportPhase _phase = ReportExportPhase.idle;
  ReportExportPhase get phase => _phase;

  String? _currentAttemptId;
  bool _inFlight = false;

  /// Run one accepted export attempt. [generate] performs the actual report
  /// generation (the caller's context-guarded wrapper around the choke point)
  /// and is invoked at most once.
  Future<void> run(Future<void> Function() generate) async {
    if (_inFlight) return; // single-flight: ignore repeated taps
    _inFlight = true;
    final attempt = _mintAttemptId();
    _currentAttemptId = attempt;
    _analytics.exportRequested();

    var advanced = false;
    Future<void> advanceOnce() async {
      // The ONE continuation: generate exactly once, and never for a superseded
      // attempt (stale callback protection).
      if (advanced || _currentAttemptId != attempt) return;
      advanced = true;
      _phase = ReportExportPhase.generating;
      await generate();
      _phase = ReportExportPhase.completed;
      _analytics.exportCompleted();
    }

    try {
      final showAd = await _shouldShowAd(attempt);
      if (_currentAttemptId != attempt) return; // superseded
      if (showAd) {
        _phase = ReportExportPhase.presentingAd;
        final outcome = await _gateway.showIfAvailable();
        _recordOutcome(outcome);
        if (_currentAttemptId != attempt) return; // superseded during present
      }
      // Fail-open: every path (ad shown / skipped / failed / interrupted) lands
      // here and generates exactly once.
      await advanceOnce();
    } finally {
      if (_currentAttemptId == attempt) {
        _inFlight = false;
        _currentAttemptId = null;
        _phase = ReportExportPhase.idle;
      }
    }
  }

  /// Evaluate the full ad gate (§8). ANY false term ⇒ no ad.
  Future<bool> _shouldShowAd(String attempt) async {
    if (!_reportAdsEnabled()) return false;
    if (!_adConfigAvailable()) return false;

    _phase = ReportExportPhase.resolvingEntitlement;
    final state = await _entitlement.resolve();
    if (_currentAttemptId != attempt) return false;
    // Only VERIFIED_INACTIVE is eligible; ACTIVE and UNKNOWN both skip the ad.
    if (state != ReportEntitlementState.verifiedInactive) return false;

    if (!await _consent.canRequestAds()) return false;
    if (_currentAttemptId != attempt) return false;

    _phase = ReportExportPhase.preparingAd;
    _analytics.adLoadRequested();
    if (!_gateway.isAvailable) await _gateway.preload();
    if (!_gateway.isAvailable) {
      _analytics.adLoadFailed();
      return false;
    }
    return true;
  }

  void _recordOutcome(ReportAdOutcome outcome) {
    switch (outcome) {
      case ReportAdOutcome.dismissed:
        _analytics.adImpression();
        _analytics.adDismissed();
      case ReportAdOutcome.failedToShow:
        _analytics.adShowFailed();
      case ReportAdOutcome.failedToLoad:
        _analytics.adLoadFailed();
      case ReportAdOutcome.unavailable:
      case ReportAdOutcome.lifecycleInterrupted:
        break;
    }
  }

  /// Opportunistic preload (§21): only when every applicable gate allows it —
  /// flag on, config present, VERIFIED_INACTIVE, and UMP permits requests.
  /// Never preloads for VERIFIED_ACTIVE / UNKNOWN, flag off, or missing config.
  Future<void> maybePreload() async {
    if (!_reportAdsEnabled() || !_adConfigAvailable()) return;
    final state = await _entitlement.resolve();
    if (state != ReportEntitlementState.verifiedInactive) return;
    if (!await _consent.canRequestAds()) return;
    await _gateway.preload();
  }
}
