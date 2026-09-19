import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backend/metrics_client.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/features/ads/ad_placement.dart';
import 'package:money_companion/features/ads/banner_ad_controller.dart';
import 'package:money_companion/features/ads/banner_ads_analytics.dart';
import 'package:money_companion/features/ads/banner_ads_providers.dart';
import 'package:money_companion/features/ads/qirsh_ad_banner.dart';
import 'package:money_companion/l10n/app_localizations.dart';

/// THE PAGE MUST NOT GROW UNDER A READER WHO IS ALREADY AT THE END OF IT.
///
/// Device QA measured the dashboard banner ending 75pt BELOW the display and
/// achievements 95pt, in every locale and theme, with the navigation clearance
/// below that entirely out of view. Goals had 25pt of room under a slot whose
/// clearance is supposed to be 120.
///
/// None of that is a layout mistake. The banner is the last direct child of the
/// list, so it materialises only once the reader reaches the end — and the ad
/// then arrived and grew the list by ~187pt while the scroll offset stayed
/// where it was. Everything the ad added, including its own lower half and the
/// clearance beneath it, went under the fold.
///
/// Every test here reproduces that sequence exactly: scroll to the very end
/// while the load is still in flight, complete it, and measure WITHOUT
/// touching the scroll position again. The fix is that the slot takes its
/// space when the height is RESOLVED rather than when the creative arrives, so
/// the extent is already right before the reader gets there.

final _silentAnalytics = BannerAdsAnalytics(
  cloudProcessingEnabled: () async => false,
  metrics: MetricsClient(),
);

/// A loader whose network round trip is held open, so a test can stand between
/// "size resolved" and "creative arrived".
class _HeldLoader implements BannerAdLoader {
  static Completer<bool>? gate;
  static int loadCalls = 0;
  static int? resolvedHeight = 187;
  static void reset() {
    gate = null;
    loadCalls = 0;
    resolvedHeight = 187;
  }

  @override
  Object? get loadedAd => null;

  @override
  Future<int?> resolveHeight(int widthPx) async => resolvedHeight;

  @override
  Future<bool> load({
    required String adUnitId,
    required int widthPx,
    required int heightPx,
    VoidCallback? onImpression,
  }) {
    loadCalls++;
    return (gate ??= Completer<bool>()).future;
  }

  @override
  void dispose() {}
}

const _clearance = 120.0;

/// The shape every affected screen has: content, then the banner as a DIRECT
/// child of the list, then the navigation clearance.
Widget _app({int blocks = 6}) {
  return ProviderScope(
    overrides: [
      bannerEligibilityProvider(AdPlacement.goals)
          .overrideWith((ref) async => true),
      bannerAdLoaderFactoryProvider.overrideWithValue(_HeldLoader.new),
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
        body: ListView(
          // Clamping, so the assertions are about extent arithmetic rather
          // than about iOS overscroll bounce settling a few pixels past the
          // end after a jump.
          physics: const ClampingScrollPhysics(),
          children: [
            for (var i = 0; i < blocks; i++)
              SizedBox(height: 300, child: Text('block $i')),
            const QirshAdBanner(placement: AdPlacement.goals),
            const SizedBox(height: _clearance),
          ],
        ),
      ),
    ),
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

/// Drives the list to its very end — the position a reader is in when the ad
/// lands late.
Future<ScrollPosition> _toEnd(WidgetTester tester) async {
  final pos =
      tester.state<ScrollableState>(find.byType(Scrollable).first).position;
  for (var i = 0; i < 20; i++) {
    if (pos.pixels >= pos.maxScrollExtent) break;
    pos.jumpTo(pos.maxScrollExtent);
    await _settle(tester);
  }
  return pos;
}

void main() {
  setUp(() {
    _HeldLoader.reset();
    BannerAdController.resetThrottleForTest();
  });

  testWidgets('the ad and its clearance are fully visible with NO further '
      'scrolling after the load completes', (tester) async {
    await tester.pumpWidget(_app());
    await _settle(tester);

    // The reader arrives at the end while the request is still in flight.
    final pos = await _toEnd(tester);
    expect(_HeldLoader.loadCalls, 1, reason: 'the request is in flight');
    final extentBefore = pos.maxScrollExtent;

    // The creative lands. Nothing else happens — no drag, no jump.
    _HeldLoader.gate!.complete(true);
    await _settle(tester);
    await _settle(tester);

    // The property is that the page did not grow by an AD's worth — roughly
    // 187pt, which is what pushed the slot off the bottom of the display. A
    // couple of points of text-metric drift between layout passes is not that.
    expect((pos.maxScrollExtent - extentBefore).abs(), lessThan(8),
        reason: 'the page must not have grown under the reader '
            '(was $extentBefore, now ${pos.maxScrollExtent})');

    final banner = tester.getRect(find.byType(QirshAdBanner));
    final viewportBottom = tester.getRect(find.byType(Scrollable).first).bottom;
    expect(banner.bottom, lessThanOrEqualTo(viewportBottom),
        reason: 'the whole ad is on screen');
    expect(viewportBottom - banner.bottom, greaterThanOrEqualTo(_clearance - 1),
        reason: 'and the navigation clearance is below it, not under the fold');
  });

  testWidgets('the slot reserves its height BEFORE the creative arrives',
      (tester) async {
    // This is the mechanism the test above depends on, asserted directly.
    await tester.pumpWidget(_app());
    await _settle(tester);
    await _toEnd(tester);

    final reserved = tester.getSize(find.byType(QirshAdBanner)).height;
    expect(reserved, greaterThan(0),
        reason: 'the space is taken while the request is still in flight');

    _HeldLoader.gate!.complete(true);
    await _settle(tester);
    expect(tester.getSize(find.byType(QirshAdBanner)).height, reserved,
        reason: 'and the size does not change when the ad lands');
  });

  testWidgets('a waiting slot shows NOTHING — no label over empty space',
      (tester) async {
    await tester.pumpWidget(_app());
    await _settle(tester);
    await _toEnd(tester);

    final label = find.descendant(
      of: find.byType(QirshAdBanner),
      matching: find.byType(Opacity),
    );
    expect(label, findsOneWidget);
    expect(tester.widget<Opacity>(label).opacity, 0,
        reason: '"Advertisement" over an empty box reads as a failed ad');
  });

  testWidgets('NO FILL collapses the slot — no permanent blank gap',
      (tester) async {
    await tester.pumpWidget(_app());
    await _settle(tester);
    final pos = await _toEnd(tester);
    expect(tester.getSize(find.byType(QirshAdBanner)).height, greaterThan(0));

    _HeldLoader.gate!.complete(false);
    await _settle(tester);
    await _settle(tester);

    expect(tester.getSize(find.byType(QirshAdBanner)).height, 0,
        reason: 'a slot that will never carry an ad must not hold space');
    // The list shrank, so the offset is briefly past the new end; the next
    // frame corrects it. What must NOT happen is a hole left behind.
    pos.jumpTo(pos.maxScrollExtent);
    await _settle(tester);
    final banner = tester.getRect(find.byType(QirshAdBanner));
    final viewportBottom = tester.getRect(find.byType(Scrollable).first).bottom;
    expect(viewportBottom - banner.bottom, greaterThanOrEqualTo(_clearance - 1),
        reason: 'the clearance is all that is left below the collapsed slot');
  });

  testWidgets('an INELIGIBLE placement reserves nothing at all',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        bannerEligibilityProvider(AdPlacement.goals)
            .overrideWith((ref) async => false),
        bannerAdLoaderFactoryProvider.overrideWithValue(_HeldLoader.new),
        bannerAdsAnalyticsProvider.overrideWithValue(_silentAnalytics),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: ListView(
            physics: const ClampingScrollPhysics(),
            children: const [
              SizedBox(height: 300),
              QirshAdBanner(placement: AdPlacement.goals),
              SizedBox(height: _clearance),
            ],
          ),
        ),
      ),
    ));
    await _settle(tester);

    expect(tester.getSize(find.byType(QirshAdBanner)).height, 0);
    expect(_HeldLoader.loadCalls, 0);
  });

  testWidgets('reserving does not make the request any earlier', (tester) async {
    // The slot is still a direct child of the list and still lazy: it takes no
    // space and asks for nothing until it is reached.
    await tester.pumpWidget(_app(blocks: 20));
    await _settle(tester);

    expect(find.byType(QirshAdBanner, skipOffstage: false), findsNothing,
        reason: 'not built at all, 6000px below the fold');
    expect(_HeldLoader.loadCalls, 0);

    await _toEnd(tester);
    expect(_HeldLoader.loadCalls, 1, reason: 'asked for only once it is reached');
  });
}
