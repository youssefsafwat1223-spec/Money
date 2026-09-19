import 'dart:async';

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

/// A SLOT REFUSED BY THE THROTTLE MUST NOT STAY DEAD FOREVER.
///
/// `BannerAdController.request` sets `_requested` BEFORE it checks the
/// throttle, which is deliberate — a refusal must not become a retry loop. The
/// consequence is that a refused controller is terminally failed, and the
/// widget goes on holding it. Waiting past the 30-second window changes
/// nothing: the slot stays blank until something rebuilds the widget from
/// scratch, which on these screens means leaving and coming back.
///
/// The fix is one retry, armed only for a throttle refusal, that drops the dead
/// controller when the window closes and lets the ORDINARY build path ask
/// again. That path is the one that owns the gates and the width, so the retry
/// inherits every check as it stands at retry time rather than at refusal time.

final _silentAnalytics = BannerAdsAnalytics(
  cloudProcessingEnabled: () async => false,
  metrics: MetricsClient(),
);

class _SpyLoader implements BannerAdLoader {
  static final List<int> widths = [];
  static void reset() => widths.clear();

  @override
  Object? get loadedAd => null;

  @override
  Future<int?> resolveHeight(int widthPx) async => 60;

  @override
  Future<bool> load({
    required String adUnitId,
    required int widthPx,
    required int heightPx,
    VoidCallback? onImpression,
  }) async {
    widths.add(widthPx);
    return false;
  }

  @override
  void dispose() {}
}

/// Eligibility as a REACTIVE input.
///
/// A `ValueNotifier` read inside the override closure is not enough: the value
/// only changes when the provider is rebuilt, and rebuilding the scope to force
/// that also resets the widget's state and its pending retry. A `StateProvider`
/// changes underneath a tree that stays put, which is the situation being
/// tested — the gate closing WHILE the retry waits.
final _eligibleProvider = StateProvider<bool>((ref) => true);
final _width = ValueNotifier<double>(400);

Widget _app() {
  return ProviderScope(
    overrides: [
      bannerEligibilityProvider(AdPlacement.goals)
          .overrideWith((ref) async => ref.watch(_eligibleProvider)),
      bannerAdLoaderFactoryProvider.overrideWithValue(_SpyLoader.new),
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

/// The time the throttle believes in. Moved by [_waitOutThrottle] in step with
/// the frames, so the fake timers and the throttle's arithmetic agree.
///
/// They do not agree by default: a widget test's timers are fake while
/// `DateTime.now` is real, so pumping long enough to fire the retry left the
/// throttle still counting real milliseconds — and a short enough window to
/// beat that was crossed by the initial settle instead. Both sides move here.
DateTime _now = DateTime.utc(2026, 9, 19, 12);

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

/// Past the throttle window and the retry's small margin, in both clocks.
Future<void> _waitOutThrottle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    _now = _now.add(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
  }
  await _settle(tester);
}

void main() {
  setUp(() {
    _SpyLoader.reset();
    BannerAdController.resetThrottleForTest();
    ReportBannerSuppression.resetForTest();
    modalRouteOpen.value = false;
    _width.value = 400;
    _now = DateTime.utc(2026, 9, 19, 12);
    BannerAdController.debugClockOverride = () => _now;
    // Long enough that the initial settle cannot accidentally cross it, short
    // enough to step over deliberately.
    BannerAdController.debugIntervalOverride = const Duration(seconds: 5);
  });

  tearDown(() {
    BannerAdController.resetThrottleForTest();
    modalRouteOpen.value = false;
  });

  /// Burns the placement's throttle so the next mount is refused.
  void consumeThrottle() {
    BannerAdController(
      placement: AdPlacement.goals,
      loader: _SpyLoader(),
    ).request(adUnitId: 'x', widthPx: 400);
  }

  testWidgets('a throttled slot retries itself once the window closes',
      (tester) async {
    consumeThrottle();
    await tester.pumpWidget(_app());
    await _settle(tester);
    expect(_SpyLoader.widths.length, 1,
        reason: 'only the throttle-burning request so far');

    await _waitOutThrottle(tester);
    await _settle(tester);

    expect(_SpyLoader.widths.length, 2,
        reason: 'the slot asked again once it was allowed to');
  });

  testWidgets('it retries ONCE, not in a loop', (tester) async {
    consumeThrottle();
    await tester.pumpWidget(_app());
    await _settle(tester);
    await _waitOutThrottle(tester);
    await _settle(tester);
    final afterFirstRetry = _SpyLoader.widths.length;

    for (var i = 0; i < 3; i++) {
      await _waitOutThrottle(tester);
      await _settle(tester);
    }
    expect(_SpyLoader.widths.length, afterFirstRetry,
        reason: 'a second refusal means the placement is genuinely busy');
  });

  testWidgets('the retry uses the width that is there NOW', (tester) async {
    consumeThrottle();
    await tester.pumpWidget(_app());
    await _settle(tester);

    _width.value = 360;
    await _settle(tester);
    await _waitOutThrottle(tester);
    await _settle(tester);

    expect(_SpyLoader.widths.last, 360,
        reason: 'not the width that was current when it was refused');
  });

  group('the retry re-checks the gates as they are AT RETRY TIME', () {
    testWidgets('entitlement lost while waiting ⇒ no request', (tester) async {
      consumeThrottle();
      await tester.pumpWidget(_app());
      await _settle(tester);
      final before = _SpyLoader.widths.length;

      // The entitlement future resolving ad-free, mid-wait.
      ProviderScope.containerOf(tester.element(find.byType(QirshAdBanner)))
          .read(_eligibleProvider.notifier)
          .state = false;
      await _settle(tester);
      await _waitOutThrottle(tester);

      expect(_SpyLoader.widths.length, before,
          reason: 'an ad-free user must not be asked for an ad');
    });

    testWidgets('a sheet opened while waiting ⇒ no request', (tester) async {
      consumeThrottle();
      await tester.pumpWidget(_app());
      await _settle(tester);
      final before = _SpyLoader.widths.length;

      modalRouteOpen.value = true;
      await _settle(tester);
      await _waitOutThrottle(tester);
      await _settle(tester);

      expect(_SpyLoader.widths.length, before,
          reason: 'the banner is covered — nothing may be requested under it');
    });

    testWidgets('unmounted while waiting ⇒ no request and no stray timer',
        (tester) async {
      consumeThrottle();
      await tester.pumpWidget(_app());
      await _settle(tester);
      final before = _SpyLoader.widths.length;

      await tester.pumpWidget(const SizedBox.shrink());
      await _waitOutThrottle(tester);

      expect(_SpyLoader.widths.length, before);
      // A timer left running past dispose fails the test binding outright, so
      // reaching here is itself the assertion.
    });
  });

  testWidgets('a NO-FILL is not retried — only a throttle refusal is',
      (tester) async {
    // The loader returns false for every request in this file, so the first
    // mount here is a genuine no-fill rather than a refusal. That is a real
    // answer from the network and must not be asked again.
    await tester.pumpWidget(_app());
    await _settle(tester);
    expect(_SpyLoader.widths.length, 1);

    await _waitOutThrottle(tester);
    await _settle(tester);
    expect(_SpyLoader.widths.length, 1,
        reason: 'no fill is an answer, not a postponement');
  });
}
