import 'package:flutter/foundation.dart';

/// How long a banner stays quiet on a surface that has just shown a full-screen
/// ad.
///
/// The Reports screen is the only surface D-19 approved for two formats: a
/// banner and the report-export interstitial. They are never on screen together
/// — a pushed full-screen route makes `ModalRoute.isCurrent` false and the
/// banner tears itself down — but "never together" is not the same as "not
/// back-to-back", and an interstitial followed immediately by a banner reads as
/// one ad break with two ads in it.
///
/// The per-placement request throttle already gives about 30 seconds of this for
/// free, since the banner's re-request on return is refused. A real export
/// normally takes longer than that, so the gap needs closing deliberately.
///
/// Static, like `BannerAdController._lastRequestAt`, and for the same reason:
/// the screen is unmounted and remounted across the export, and a per-instance
/// field would reset on exactly the event it exists to survive.
class InterstitialCooldown {
  InterstitialCooldown._();

  static const Duration window = Duration(seconds: 120);

  static DateTime? _shownAt;

  /// Overridable so the window can be crossed in a test without waiting it out.
  @visibleForTesting
  static DateTime Function() clock = DateTime.now;

  /// Record that a full-screen ad was actually PRESENTED — not requested, not
  /// loaded. Only the dismissed outcome means a human saw one.
  static void markShown() => _shownAt = clock();

  static bool get active {
    final shown = _shownAt;
    if (shown == null) return false;
    return clock().difference(shown) < window;
  }

  @visibleForTesting
  static void resetForTest() {
    _shownAt = null;
    clock = DateTime.now;
  }
}
