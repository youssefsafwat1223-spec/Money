import 'dart:async';

import 'package:google_mobile_ads/google_mobile_ads.dart';

/// One-time Google Mobile Ads SDK initialization, shared by every ad format.
///
/// This used to live as a private instance method with a private static latch
/// inside the report-export interstitial gateway. That was fine while there was
/// exactly one format; with a banner it becomes wrong twice over — the banner
/// cannot reach it, and two independent latches would let both formats race
/// `initialize()` on cold start.
///
/// Single-flight and bounded: concurrent callers await the same future, and a
/// hung platform channel resolves as "not initialized" rather than leaving every
/// future caller waiting forever. It is deliberately NOT a Riverpod provider —
/// the SDK's own state is process-global, so modelling it as anything else would
/// be a lie a test could not enforce.
class MobileAdsInitializer {
  MobileAdsInitializer._();

  static const Duration _timeout = Duration(seconds: 10);

  static bool _initialized = false;
  static Future<void>? _inFlight;

  /// True once the SDK's own initializer has completed successfully.
  /// (Deliberately not naming the call in prose: a guard test counts call
  /// sites by grepping for it, and a doc comment is not an exemption.)
  static bool get isInitialized => _initialized;

  /// Initialize once. Never throws: a failure leaves [isInitialized] false and
  /// callers simply get no ad, which every caller already treats as normal.
  static Future<void> ensureInitialized() {
    if (_initialized) return Future<void>.value();
    return _inFlight ??= _run();
  }

  static Future<void> _run() async {
    try {
      await MobileAds.instance.initialize().timeout(_timeout);
      _initialized = true;
    } catch (_) {
      // Left false on purpose. A retry is allowed on the next opportunity
      // because `_inFlight` is cleared below — but nothing retries in a loop,
      // since every caller is driven by a user-visible ad opportunity.
    } finally {
      _inFlight = null;
    }
  }

  /// Test-only reset. The SDK latch is process-global, so a test that asserts
  /// first-call behaviour has to be able to put it back.
  static void resetForTest() {
    _initialized = false;
    _inFlight = null;
  }
}
