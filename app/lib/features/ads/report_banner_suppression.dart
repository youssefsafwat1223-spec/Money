import 'package:flutter/foundation.dart';

/// Why the Reports banner is not allowed to serve right now.
///
/// Reports is the one surface D-19 approved for TWO formats, and keeping them
/// apart takes more than the route gate. Two reasons live here.
///
/// ## 1. An export ad journey is in flight
///
/// The route gate covers the configuration page and the ad notice, because both
/// are Flutter routes. It covers nothing else, and that leaves two real windows
/// where the banner is on screen and free to request:
///
///   * between the configuration page popping and the notice appearing — the
///     coordinator is resolving entitlement and preloading, both network round
///     trips;
///   * during the interstitial itself. A native full-screen ad pushes NO
///     Flutter route, so `ModalRoute.isCurrent` stays true and
///     `ModalRouteObserver` never sees it (it counts `PopupRoute` only).
///
/// A configuration visit longer than the 30-second request throttle leaves the
/// throttle free, so the banner can and does request in those windows. The
/// earlier claim that the two formats were *structurally* exclusive was wrong;
/// this is what makes it true.
///
/// ## 2. An interstitial was just shown
///
/// "Never together" is not "never back-to-back". An interstitial followed
/// immediately by a banner reads as one ad break with two ads in it.
///
/// Static, like `BannerAdController._lastRequestAt`, and for the same reason:
/// the screen is unmounted and remounted across the export, so per-instance
/// state would reset on exactly the event it exists to survive.
class ReportBannerSuppression {
  ReportBannerSuppression._();

  static const Duration cooldown = Duration(seconds: 120);

  /// A COUNTER, not a flag. Single-flight should mean one journey at a time,
  /// but a counter cannot be left stuck open by an overlapping pair, and
  /// "stuck open" here means the banner never returns.
  static int _journeyDepth = 0;
  static DateTime? _adShownAt;

  /// Overridable so a test can cross the cooldown without waiting it out.
  @visibleForTesting
  static DateTime Function() clock = DateTime.now;

  /// The export ad journey has started: entitlement, consent, preload, notice,
  /// presentation and the generation that follows. Paired with [endJourney] in
  /// a `finally`.
  static void beginJourney() => _journeyDepth++;

  static void endJourney() {
    if (_journeyDepth > 0) _journeyDepth--;
  }

  /// A full-screen ad was actually PRESENTED — not requested, not loaded.
  static void markAdShown() => _adShownAt = clock();

  static bool get journeyActive => _journeyDepth > 0;

  static bool get inCooldown {
    final shown = _adShownAt;
    if (shown == null) return false;
    return clock().difference(shown) < cooldown;
  }

  /// Either reason. This is what the eligibility gate reads.
  static bool get active => journeyActive || inCooldown;

  @visibleForTesting
  static void resetForTest() {
    _journeyDepth = 0;
    _adShownAt = null;
    clock = DateTime.now;
  }
}
