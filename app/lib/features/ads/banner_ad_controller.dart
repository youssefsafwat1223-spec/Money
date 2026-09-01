import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import 'ad_placement.dart';
import 'mobile_ads_initializer.dart';

/// What a banner slot is doing right now. The widget renders from this and
/// nothing else, so every visual state is reachable in a test.
enum BannerAdStatus {
  /// Nothing requested. The slot occupies ZERO height and is not in the layout.
  idle,

  /// A size has been resolved and a load is in flight. Still zero height —
  /// see the note on [BannerAdController] about why nothing is reserved yet.
  loading,

  /// An ad is loaded and ready to mount. This is the only state with height.
  loaded,

  /// The load failed, or the network returned no fill. Zero height, forever,
  /// for this mount. There is no retry.
  failed,
}

/// Everything the controller needs from the SDK, behind an interface so the
/// whole lifecycle is testable without a platform channel.
///
/// This is the ONLY seam Google types cross. `BannerAd`, `AdSize` and friends
/// do not appear in the controller's public surface, in the widget, or in any
/// feature file — an architecture test enforces that.
abstract class BannerAdLoader {
  /// The adaptive height for [widthPx], or null when the platform cannot
  /// supply one.
  Future<int?> resolveHeight(int widthPx);

  /// Request one banner. Completes with true once the ad is loaded, false on
  /// failure/no-fill. Never throws.
  ///
  /// [onImpression] fires when the SDK reports the ad was actually displayed.
  /// That is the only impression signal worth recording: "we asked for an ad"
  /// and "a human saw one" are very different facts, and only the SDK knows the
  /// second.
  Future<bool> load({
    required String adUnitId,
    required int widthPx,
    required int heightPx,
    VoidCallback? onImpression,
  });

  /// The loaded ad, for mounting. Null unless the last [load] returned true.
  Object? get loadedAd;

  void dispose();
}

/// The real google_mobile_ads implementation.
class AdMobBannerAdLoader implements BannerAdLoader {
  BannerAd? _ad;
  bool _disposed = false;

  static const Duration _loadTimeout = Duration(seconds: 20);

  @override
  Object? get loadedAd => _ad;

  @override
  Future<int?> resolveHeight(int widthPx) async {
    // 9.0.0 deprecates `getAnchoredAdaptiveBannerAdSize` and
    // `getCurrentOrientationAnchoredAdaptiveBannerAdSize`; this is the
    // supported call. It is a platform-channel round trip and it can return
    // null, so it is resolved BEFORE anything is reserved on screen.
    //
    // Anchored (not inline) adaptive, inside scrolling content, is a deliberate
    // mismatch with Google's format guidance: inline adaptive finalises its
    // height only AFTER the ad loads, via `getPlatformAdSize`, which is exactly
    // the late layout change this design exists to avoid. Anchored adaptive
    // returns a height that is stable for a given width/device before any load,
    // which is what makes a jank-free slot possible at all.
    try {
      final size = await AdSize.getLargeAnchoredAdaptiveBannerAdSize(widthPx)
          .timeout(const Duration(seconds: 5));
      return size?.height;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> load({
    required String adUnitId,
    required int widthPx,
    required int heightPx,
    VoidCallback? onImpression,
  }) async {
    if (_disposed) return false;
    await MobileAdsInitializer.ensureInitialized();
    if (!MobileAdsInitializer.isInitialized || _disposed) return false;

    final completer = Completer<bool>();
    void finish(bool ok) {
      if (!completer.isCompleted) completer.complete(ok);
    }

    final ad = BannerAd(
      adUnitId: adUnitId,
      size: AdSize(width: widthPx, height: heightPx),
      // Matches the interstitial and docs/REPORT_ADS_SYSTEM.md §13: this app
      // ships no ATT prompt and no IDFA, so every request is non-personalized.
      request: const AdRequest(
        nonPersonalizedAds: true,
        extras: {'npa': '1'},
      ),
      listener: BannerAdListener(
        onAdLoaded: (_) => finish(true),
        onAdFailedToLoad: (ad, _) {
          ad.dispose();
          finish(false);
        },
        onAdImpression: (_) => onImpression?.call(),
      ),
    );
    _ad = ad;

    try {
      unawaited(ad.load().catchError((Object _) => finish(false)));
      final ok = await completer.future.timeout(_loadTimeout, onTimeout: () {
        // A dead callback must not leave the slot in `loading` forever.
        return false;
      });
      if (!ok || _disposed) {
        _ad = null;
        ad.dispose();
        return false;
      }
      return true;
    } catch (_) {
      _ad = null;
      ad.dispose();
      return false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _ad?.dispose();
    _ad = null;
  }
}

/// Owns ONE banner's SDK lifecycle for ONE mounted placement.
///
/// ## Why the slot has no height until the ad is loaded
///
/// The obvious design reserves the ad's height up front so the arriving
/// creative does not push content down. It has a worse failure mode: on a
/// no-fill — which is common — the user is left looking at an empty box in a
/// finance app, and collapsing that box later moves a tappable transaction row
/// under a finger that is already on its way down. Google's own placement
/// guidance calls out exactly that as an accidental-click source.
///
/// So the sequence is: resolve the height (cheap, no ad), request the ad, and
/// insert the slot ONLY once an ad is in hand. A failure is then completely
/// invisible — no box, no collapse, no movement — and a success is a single
/// insertion that never subsequently changes size. Once shown, the slot's
/// height is fixed for the life of the mount; nothing here can shrink it.
///
/// ## One request per mount
///
/// A Flutter rebuild does not re-request. Neither does scrolling, a theme
/// change, or a provider invalidation. Only a fresh mount does — and a mount is
/// gated by a visibility throttle so that flicking between tabs cannot turn
/// into a request storm, which is the pattern that reads as invalid traffic.
class BannerAdController extends ChangeNotifier {
  BannerAdController({
    required this.placement,
    required BannerAdLoader loader,
    void Function(String event, String placementKey)? onEvent,
    Duration minimumRequestInterval = const Duration(seconds: 30),
    DateTime Function()? clock,
  })  : _loader = loader,
        _onEvent = onEvent,
        _minimumRequestInterval = minimumRequestInterval,
        _clock = clock ?? DateTime.now;

  final AdPlacement placement;
  final BannerAdLoader _loader;

  /// Operational telemetry only, and deliberately only on the paths where an ad
  /// was actually attempted.
  ///
  /// There is NO "suppressed because ad-free" or "suppressed because no
  /// consent" event. Those were in the first draft of the plan and a reviewer
  /// caught the contradiction: the design promises an ad-free user produces no
  /// telemetry indicating an impression opportunity, and an event whose whole
  /// meaning is "this user would have been shown an ad" is exactly that.
  final void Function(String event, String placementKey)? _onEvent;
  final Duration _minimumRequestInterval;
  final DateTime Function() _clock;

  /// Last request time PER PLACEMENT, across mounts. Static because the point
  /// is to survive the unmount/remount that a tab switch causes — a per-instance
  /// field would reset on exactly the event it exists to throttle.
  static final Map<AdPlacement, DateTime> _lastRequestAt = {};

  BannerAdStatus _status = BannerAdStatus.idle;
  BannerAdStatus get status => _status;

  int? _heightPx;

  /// The slot's height once an ad is loaded, else null. Never changes after it
  /// becomes non-null for a given mount.
  int? get heightPx => _status == BannerAdStatus.loaded ? _heightPx : null;

  /// The loaded ad object, for the widget to mount. Null unless [status] is
  /// [BannerAdStatus.loaded].
  Object? get ad => _status == BannerAdStatus.loaded ? _loader.loadedAd : null;

  bool _disposed = false;
  bool _requested = false;

  /// Whether a request is allowed right now under the per-placement throttle.
  @visibleForTesting
  bool get throttled {
    final last = _lastRequestAt[placement];
    if (last == null) return false;
    return _clock().difference(last) < _minimumRequestInterval;
  }

  /// Request exactly one banner, at most once for this controller.
  ///
  /// [widthPx] is the logical width available to the slot. Below 320 the
  /// request is refused outright: the narrowest standard banner is 320 wide,
  /// and a slot narrower than its content either clips the creative or scrolls
  /// it horizontally — both are ad-placement problems, not cosmetic ones.
  Future<void> request({required String adUnitId, required int widthPx}) async {
    if (_disposed || _requested) return;
    _requested = true;

    if (widthPx < 320) {
      _set(BannerAdStatus.failed);
      return;
    }
    if (throttled) {
      _set(BannerAdStatus.failed);
      return;
    }
    _lastRequestAt[placement] = _clock();
    _set(BannerAdStatus.loading);
    _emit('banner_ad_requested');

    final height = await _loader.resolveHeight(widthPx);
    if (_disposed) return;
    // A null adaptive height is not a reason to give up — the standard 50dp
    // banner is a legitimate size on every device, and refusing here would
    // silently disable the placement on whatever platform returned null.
    final resolved = height ?? 50;

    final ok = await _loader.load(
      adUnitId: adUnitId,
      widthPx: widthPx,
      heightPx: resolved,
      onImpression: () => _emit('banner_ad_impression'),
    );
    if (_disposed) return;
    if (!ok) {
      _set(BannerAdStatus.failed);
      _emit('banner_ad_failed');
      return;
    }
    _heightPx = resolved;
    _set(BannerAdStatus.loaded);
    _emit('banner_ad_loaded');
  }

  void _emit(String event) {
    try {
      _onEvent?.call(event, placement.key);
    } catch (_) {
      // Telemetry can never affect an ad, and an ad can never affect the app.
    }
  }

  void _set(BannerAdStatus next) {
    if (_status == next) return;
    _status = next;
    notifyListeners();
  }

  @visibleForTesting
  static void resetThrottleForTest() => _lastRequestAt.clear();

  @override
  void dispose() {
    _disposed = true;
    _loader.dispose();
    super.dispose();
  }
}
