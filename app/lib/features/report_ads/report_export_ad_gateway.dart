import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import 'report_ads_build_config.dart';

/// Qirsh-owned terminal outcome of one report-export ad opportunity. The Google
/// SDK types never leak past this file (§18). Every outcome is non-blocking for
/// the caller — the coordinator proceeds to report generation regardless.
enum ReportAdOutcome {
  /// The interstitial was shown and then dismissed by the user (one impression).
  dismissed,

  /// No ad was preloaded / available to show.
  unavailable,

  /// Loading a new interstitial failed.
  failedToLoad,

  /// A loaded interstitial failed at show time.
  failedToShow,

  /// The app was interrupted (backgrounded / disposed) during presentation.
  lifecycleInterrupted,
}

/// Narrow abstraction over a STANDARD interstitial. Responsibilities: preload,
/// availability, show-once, map callbacks to [ReportAdOutcome], cleanup. It has
/// NO report logic and NO entitlement logic — those live in the coordinator.
abstract class ReportExportAdGateway {
  /// Preload an interstitial if configuration allows. Idempotent; bounded (a
  /// single in-flight load, no retry loop).
  Future<void> preload();

  /// Whether a loaded interstitial is ready to show right now.
  bool get isAvailable;

  /// Show the preloaded interstitial exactly once. Returns [ReportAdOutcome]
  /// after the ad is dismissed / fails / is unavailable. Never throws.
  Future<ReportAdOutcome> showIfAvailable();

  void dispose();
}

/// google_mobile_ads implementation. Uses the build-time TEST unit in dev and a
/// dart-defined production unit in release (null → unavailable, fail closed).
class AdMobReportExportAdGateway implements ReportExportAdGateway {
  AdMobReportExportAdGateway({TargetPlatform? platform})
      : _platform = platform ?? defaultTargetPlatform;

  final TargetPlatform _platform;

  InterstitialAd? _ad;
  bool _loading = false;
  static bool _mobileAdsInitialized = false;

  String? get _unitId => ReportAdsBuildConfig.interstitialUnitId(_platform);

  /// Initialize the Google Mobile Ads SDK once. Only reached after the caller
  /// has confirmed UMP canRequestAds and a usable ad-unit id exists.
  Future<void> _ensureMobileAds() async {
    if (_mobileAdsInitialized) return;
    await MobileAds.instance.initialize();
    _mobileAdsInitialized = true;
  }

  @override
  bool get isAvailable => _ad != null;

  @override
  Future<void> preload() async {
    if (_ad != null || _loading) return; // bounded: one in-flight load, no loop
    final unitId = _unitId;
    if (unitId == null) return; // no ad configuration → nothing to preload
    _loading = true;
    await _ensureMobileAds();
    final completer = Completer<void>();
    InterstitialAd.load(
      adUnitId: unitId,
      // V1 is non-personalized (no ATT / IDFA): request NPA explicitly.
      request: const AdRequest(extras: {'npa': '1'}),
      adLoadCallback: InterstitialAdLoadCallback(
        onAdLoaded: (ad) {
          _ad = ad;
          _loading = false;
          if (!completer.isCompleted) completer.complete();
        },
        onAdFailedToLoad: (error) {
          _ad = null;
          _loading = false;
          if (!completer.isCompleted) completer.complete();
        },
      ),
    );
    return completer.future;
  }

  @override
  Future<ReportAdOutcome> showIfAvailable() async {
    final ad = _ad;
    if (ad == null) return ReportAdOutcome.unavailable;
    _ad = null; // consume: an interstitial may be shown only once

    final completer = Completer<ReportAdOutcome>();
    void finish(ReportAdOutcome outcome) {
      if (!completer.isCompleted) completer.complete(outcome);
    }

    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (ad) {
        ad.dispose();
        finish(ReportAdOutcome.dismissed);
      },
      onAdFailedToShowFullScreenContent: (ad, error) {
        ad.dispose();
        finish(ReportAdOutcome.failedToShow);
      },
    );

    try {
      await ad.show();
    } catch (_) {
      ad.dispose();
      finish(ReportAdOutcome.failedToShow);
    }
    return completer.future;
  }

  @override
  void dispose() {
    _ad?.dispose();
    _ad = null;
  }
}
