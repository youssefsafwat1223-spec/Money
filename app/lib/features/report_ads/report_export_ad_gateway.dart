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
  int _loadGeneration = 0;
  void Function()? _cancelPresentation;
  static bool _mobileAdsInitialized = false;

  // Bounds for every SDK await (audit H-5). Generous rather than tight: the
  // goal is to guarantee termination, not to police the network. An interstitial
  // presentation is seconds long, so minutes here only catches a dead callback.
  static const Duration _initTimeout = Duration(seconds: 10);
  static const Duration _loadTimeout = Duration(seconds: 30);
  static const Duration _showTimeout = Duration(minutes: 5);

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
    // Audit C-4/A1: require the COMPLETE configuration, not just an ad unit.
    // Initialising the SDK with a unit id but an absent application id raises
    // the SDK's invalid-initialization exception (on iOS an empty
    // GADApplicationIdentifier), so this precondition must match the
    // coordinator's rather than being weaker than it.
    if (!ReportAdsBuildConfig.isConfiguredFor(_platform)) return;
    final unitId = _unitId;
    if (unitId == null) return; // no ad configuration → nothing to preload
    _loading = true;
    final generation = ++_loadGeneration;
    void invalidateLoad() {
      if (generation != _loadGeneration) return;
      _loadGeneration++;
      _loading = false;
      _ad?.dispose();
      _ad = null;
    }

    // Audit H-5: every await here is bounded and `_loading` is released on EVERY
    // path. Previously an initialize() throw left `_loading` true forever (so no
    // ad could ever load again) and propagated into the export path, suppressing
    // the user's report entirely.
    try {
      await _ensureMobileAds().timeout(_initTimeout);
      if (generation != _loadGeneration) return;
      final completer = Completer<void>();
      // The Future returned by load() is NOT the completion signal (the
      // callbacks are), but it CAN reject on a platform-channel failure before
      // either callback fires. Unawaited, that became an unhandled async error
      // and the completer never completed — a permanent hang.
      unawaited(
        InterstitialAd.load(
          adUnitId: unitId,
          // V1 is non-personalized (no ATT / IDFA): request NPA explicitly.
          request: const AdRequest(extras: {'npa': '1'}),
          adLoadCallback: InterstitialAdLoadCallback(
            onAdLoaded: (ad) {
              if (generation != _loadGeneration) {
                ad.dispose();
                if (!completer.isCompleted) completer.complete();
                return;
              }
              _ad = ad;
              if (!completer.isCompleted) completer.complete();
            },
            onAdFailedToLoad: (error) {
              invalidateLoad();
              if (!completer.isCompleted) completer.complete();
            },
          ),
        ).catchError((Object _) {
          invalidateLoad();
          if (!completer.isCompleted) completer.complete();
        }),
      );
      await completer.future.timeout(_loadTimeout, onTimeout: invalidateLoad);
    } catch (_) {
      // Fail closed for ads, fail OPEN for the report: the coordinator sees
      // "no ad available" and proceeds to generate.
      invalidateLoad();
    } finally {
      if (generation == _loadGeneration) _loading = false;
    }
  }

  @override
  Future<ReportAdOutcome> showIfAvailable() async {
    final ad = _ad;
    if (ad == null) return ReportAdOutcome.unavailable;
    _ad = null; // consume: an interstitial may be shown only once

    final completer = Completer<ReportAdOutcome>();
    var disposed = false;
    void disposeAd() {
      if (disposed) return;
      disposed = true;
      ad.dispose();
    }

    void finish(ReportAdOutcome outcome) {
      if (!completer.isCompleted) completer.complete(outcome);
    }

    _cancelPresentation = disposeAd;

    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (ad) {
        disposeAd();
        finish(ReportAdOutcome.dismissed);
      },
      onAdFailedToShowFullScreenContent: (ad, error) {
        disposeAd();
        finish(ReportAdOutcome.failedToShow);
      },
    );

    // Audit H-5: the completer previously resolved ONLY from a terminal
    // callback. If the ad activity died without delivering one (process
    // interruption), `showIfAvailable()` never completed, `_inFlight` stayed
    // true, and every later Export tap was silently swallowed for the rest of
    // the session. This is also the only path that can now actually produce
    // `lifecycleInterrupted`, which nothing used to return. Schedule the whole
    // trigger + callback sequence as one Future so the timeout is armed BEFORE
    // `ad.show()` is invoked; the platform-method Future itself may hang.
    final presentation = Future<ReportAdOutcome>.microtask(() async {
      try {
        await ad.show();
      } catch (_) {
        disposeAd();
        finish(ReportAdOutcome.failedToShow);
      }
      return completer.future;
    });
    try {
      return await presentation.timeout(_showTimeout, onTimeout: () {
        disposeAd();
        finish(ReportAdOutcome.lifecycleInterrupted);
        return ReportAdOutcome.lifecycleInterrupted;
      });
    } finally {
      if (identical(_cancelPresentation, disposeAd)) {
        _cancelPresentation = null;
      }
    }
  }

  void _abandonOpportunity() {
    // Invalidate first: a load callback racing this cleanup must dispose its ad
    // instead of publishing it as available for a later export.
    _loadGeneration++;
    _loading = false;
    _ad?.dispose();
    _ad = null;
    _cancelPresentation?.call();
    _cancelPresentation = null;
  }

  @override
  void dispose() => _abandonOpportunity();
}
