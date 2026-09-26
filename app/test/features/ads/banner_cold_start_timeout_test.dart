import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backend/metrics_client.dart';
import 'package:money_companion/core/router/modal_route_observer.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/features/ads/ad_placement.dart';
import 'package:money_companion/features/ads/banner_ad_controller.dart';
import 'package:money_companion/features/ads/banner_ads_analytics.dart';
import 'package:money_companion/features/ads/banner_ads_providers.dart';
import 'package:money_companion/features/ads/qirsh_ad_banner.dart';
import 'package:money_companion/features/ads/report_banner_suppression.dart';
import 'package:money_companion/l10n/app_localizations.dart';

/// A COLD-START TIMEOUT MUST NOT KILL THE SLOT FOR THE WHOLE MOUNT.
///
/// Measured on a real iPhone 13: the FIRST `BannerAd.load()` after
/// `MobileAds.initialize()` answered at 20072ms, against warm loads of 492ms,
/// 546ms, 549ms, 1536ms and 1945ms. `_loadTimeout` is 20 seconds, so the first
/// request on every cold launch lost that race and the slot collapsed
/// permanently — on whichever surface the user happened to open first.
///
/// `onAdFailedToLoad` fired ZERO times across that entire session, which is the
/// fact that makes this a client-side timeout rather than a no-fill. The SDK was
/// not saying no; it had not finished saying anything.
///
/// So the two cases must be told apart:
///
///   * timeout  -> the absence of an answer -> one retry is warranted
///   * no-fill  -> a real answer            -> no retry, ever
///
/// These tests pin exactly that, and pin that the retry still waits for the
/// per-placement throttle rather than treating slowness as a licence to spam.

final _silentAnalytics = BannerAdsAnalytics(
  cloudProcessingEnabled: () async => false,
  metrics: MetricsClient(),
);

/// Fails the first load and succeeds afterwards, reporting the first failure as
/// either a timeout or a no-fill depending on [timedOut].
class _ColdLoader
    implements BannerAdLoader, TimeoutAwareBannerLoader {
  _ColdLoader();

  static int calls = 0;
  static bool timedOut = true;
  static void reset() {
    calls = 0;
    timedOut = true;
  }

  bool _lastTimedOut = false;

  @override
  Object? get loadedAd => _loaded ? const Object() : null;
  bool _loaded = false;

  @override
  bool get lastLoadTimedOut => _lastTimedOut;

  @override
  Future<int?> resolveHeight(int widthPx) async => 60;

  @override
  Future<bool> load({
    required String adUnitId,
    required int widthPx,
    required int heightPx,
    VoidCallback? onImpression,
  }) async {
    calls++;
    if (calls == 1) {
      _lastTimedOut = timedOut;
      return false;
    }
    _lastTimedOut = false;
    _loaded = true;
    return true;
  }

  @override
  void dispose() {}
}

final _width = ValueNotifier<double>(400);

Widget _app() {
  return ProviderScope(
    overrides: [
      bannerEligibilityProvider(AdPlacement.goals)
          .overrideWith((ref) async => true),
      bannerAdLoaderFactoryProvider.overrideWithValue(_ColdLoader.new),
      bannerAdsAnalyticsProvider.overrideWithValue(_silentAnalytics),
    ],
    child: MaterialApp(
      locale: const Locale('ar'),
      supportedLocales: AppL10n.supportedLocales,
      localizationsDelegates: const [
        ...AppL10n.localizationsDelegates,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: AppTheme.dark,
      home: Scaffold(
        body: Align(
          alignment: Alignment.topCenter,
          child: ValueListenableBuilder<double>(
            valueListenable: _width,
            builder: (context, w, _) => SizedBox(
              width: w,
              child: const QirshAdBanner(placement: AdPlacement.goals),
            ),
          ),
        ),
      ),
    ),
  );
}

DateTime _now = DateTime.utc(2026, 9, 26, 12);

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

/// Steps both clocks — the fake timers and the throttle's `DateTime` — past the
/// window, the way `banner_throttle_retry_test.dart` does.
Future<void> _waitOutThrottle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    _now = _now.add(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
  }
  await _settle(tester);
}

void main() {
  setUp(() {
    _ColdLoader.reset();
    BannerAdController.resetThrottleForTest();
    ReportBannerSuppression.resetForTest();
    modalRouteOpen.value = false;
    _width.value = 400;
    _now = DateTime.utc(2026, 9, 26, 12);
    BannerAdController.debugClockOverride = () => _now;
    BannerAdController.debugIntervalOverride = const Duration(seconds: 5);
  });

  tearDown(() {
    BannerAdController.resetThrottleForTest();
    modalRouteOpen.value = false;
  });

  testWidgets('a TIMED-OUT first load is retried once and then succeeds',
      (tester) async {
    _ColdLoader.timedOut = true;

    await tester.pumpWidget(_app());
    await _settle(tester);
    expect(_ColdLoader.calls, 1, reason: 'the cold request, which timed out');

    await _waitOutThrottle(tester);

    expect(_ColdLoader.calls, 2,
        reason: 'the timeout is the absence of an answer, so ask once more');
  });

  testWidgets('a NO-FILL first load is never retried', (tester) async {
    // THE important half. A retry on a real no-fill would turn every unfilled
    // slot into two requests, which is both pointless and a policy problem.
    _ColdLoader.timedOut = false;

    await tester.pumpWidget(_app());
    await _settle(tester);
    expect(_ColdLoader.calls, 1);

    await _waitOutThrottle(tester);

    expect(_ColdLoader.calls, 1,
        reason: 'the network answered — asking again changes nothing');
  });

  testWidgets('the timeout retry happens ONCE, not in a loop', (tester) async {
    _ColdLoader.timedOut = true;

    await tester.pumpWidget(_app());
    await _settle(tester);
    await _waitOutThrottle(tester);
    expect(_ColdLoader.calls, 2);

    // Several more windows: a second retry would mean the one-shot latch leaks.
    for (var i = 0; i < 3; i++) {
      await _waitOutThrottle(tester);
    }
    expect(_ColdLoader.calls, 2, reason: 'one retry, not a retry loop');
  });

  testWidgets('the retry still waits for the throttle window', (tester) async {
    // A slow first request must not become a licence to bypass the rate limit.
    _ColdLoader.timedOut = true;

    await tester.pumpWidget(_app());
    await _settle(tester);
    expect(_ColdLoader.calls, 1);

    // One second in, well inside the 5-second test window.
    _now = _now.add(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await _settle(tester);

    expect(_ColdLoader.calls, 1,
        reason: 'still inside the window — the retry has not fired yet');
  });

  test('a loader that is NOT timeout-aware is treated as a real answer', () {
    // The compatibility guarantee: the other nine fakes in this directory
    // implement `BannerAdLoader` ONLY, and must keep meaning "the network
    // answered" so they get no retry.
    expect(_NoOpLoader(), isNot(isA<TimeoutAwareBannerLoader>()));
  });
}

class _NoOpLoader implements BannerAdLoader {
  @override
  Object? get loadedAd => null;
  @override
  Future<int?> resolveHeight(int widthPx) async => null;
  @override
  Future<bool> load({
    required String adUnitId,
    required int widthPx,
    required int heightPx,
    VoidCallback? onImpression,
  }) async =>
      false;
  @override
  void dispose() {}
}
