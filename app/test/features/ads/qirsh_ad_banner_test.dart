import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/router/modal_route_observer.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/features/ads/ad_placement.dart';
import 'package:money_companion/features/ads/banner_ad_controller.dart';
import 'package:money_companion/features/ads/banner_ads_analytics.dart';
import 'package:money_companion/features/ads/banner_ads_providers.dart';
import 'package:money_companion/features/ads/qirsh_ad_banner.dart';
import 'package:money_companion/core/backend/metrics_client.dart';
import 'package:money_companion/l10n/app_localizations.dart';

/// The banner's GATES, at the widget level.
///
/// Every test here answers one question: did an ad request happen, and did any
/// pixel appear? The bar for "no" is absolute — an ad-free user, a user who
/// declined consent, and a user on a background tab must each produce zero
/// requests and zero height, not a small or brief one.
///
/// `AdWidget` is a platform view and cannot render in a widget test, so the
/// loader is always faked and the assertions are about REQUESTS and LAYOUT
/// rather than about painted creative. That is the right boundary: everything
/// this app decides happens before the SDK is called.

/// Telemetry that records nothing and, crucially, touches no database. The real
/// sink reads user settings for its consent gate; a widget test must not need a
/// database open just to prove a banner did or did not request an ad.
final _silentAnalytics = BannerAdsAnalytics(
  cloudProcessingEnabled: () async => false,
  metrics: MetricsClient(),
);

class _SpyLoader implements BannerAdLoader {
  static int loadCalls = 0;
  static int resolveCalls = 0;
  static void reset() {
    loadCalls = 0;
    resolveCalls = 0;
  }

  @override
  Object? get loadedAd => null;

  @override
  Future<int?> resolveHeight(int widthPx) async {
    resolveCalls++;
    return 60;
  }

  @override
  Future<bool> load({
    required String adUnitId,
    required int widthPx,
    required int heightPx,
    VoidCallback? onImpression,
  }) async {
    loadCalls++;
    // Returns false so no AdWidget is ever mounted: a platform view cannot be
    // instantiated in a widget test. The request itself is what is under test.
    return false;
  }

  @override
  void dispose() {}
}

Widget _app({
  required bool eligible,
  Widget? wrapper,
  Locale locale = const Locale('ar'),
}) {
  const banner = QirshAdBanner(placement: AdPlacement.transactionsList);
  return ProviderScope(
    overrides: [
      bannerEligibilityProvider(AdPlacement.transactionsList)
          .overrideWith((ref) async => eligible),
      bannerAdLoaderFactoryProvider.overrideWithValue(_SpyLoader.new),
      bannerAdsAnalyticsProvider.overrideWithValue(_silentAnalytics),
    ],
    child: MaterialApp(
      locale: locale,
      supportedLocales: AppL10n.supportedLocales,
      localizationsDelegates: const [
        ...AppL10n.localizationsDelegates,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: AppTheme.dark,
      home: Scaffold(
        // Deliberately NOT a ListView: a zero-extent child is not retained by a
        // scroll viewport, so `find.byType` could not see the suppressed
        // banner — and "it took no space" is exactly what must be asserted.
        body: Align(
          alignment: Alignment.topCenter,
          child: wrapper ?? banner,
        ),
      ),
    ),
  );
}

/// The size of the banner subtree — 0 means the widget took no space at all.
Size _bannerSize(WidgetTester tester) =>
    tester.getSize(find.byType(QirshAdBanner));

void main() {
  setUp(() {
    _SpyLoader.reset();
    BannerAdController.resetThrottleForTest();
    modalRouteOpen.value = false;
  });

  testWidgets('an INELIGIBLE user gets zero height and zero requests',
      (tester) async {
    // This single case covers flag-off, ad-free entitlement, unknown/stale
    // entitlement and declined consent: `bannerEligibilityProvider` folds all
    // four into one answer, and the widget's contract is that a false answer
    // means nothing at all happens.
    await tester.pumpWidget(_app(eligible: false));
    await tester.pumpAndSettle();

    expect(_bannerSize(tester).height, 0);
    expect(_SpyLoader.loadCalls, 0);
    expect(_SpyLoader.resolveCalls, 0);
    expect(find.text('إعلان'), findsNothing,
        reason: 'no label without an ad — the label is not chrome');
  });

  testWidgets('eligibility that has not ANSWERED yet requests nothing',
      (tester) async {
    // A pending lookup, not a fast one: a momentary slot for an ad-free user is
    // still a slot, so "we do not know yet" must behave exactly as "no".
    final pending = Completer<bool>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          bannerEligibilityProvider(AdPlacement.transactionsList)
              .overrideWith((ref) => pending.future),
          bannerAdLoaderFactoryProvider.overrideWithValue(_SpyLoader.new),
          bannerAdsAnalyticsProvider.overrideWithValue(_silentAnalytics),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: QirshAdBanner(placement: AdPlacement.transactionsList),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(_SpyLoader.loadCalls, 0);
    expect(tester.getSize(find.byType(QirshAdBanner)).height, 0);

    pending.complete(false);
    await tester.pumpAndSettle();
    expect(_SpyLoader.loadCalls, 0, reason: 'and a NO answer stays no');
  });

  testWidgets('an ELIGIBLE user requests exactly one ad', (tester) async {
    await tester.pumpWidget(_app(eligible: true));
    await tester.pumpAndSettle();
    expect(_SpyLoader.loadCalls, 1);
  });

  testWidgets('rebuilding does not buy a second ad', (tester) async {
    await tester.pumpWidget(_app(eligible: true));
    await tester.pumpAndSettle();
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(_SpyLoader.loadCalls, 1);
  });

  testWidgets('a load failure leaves NO slot behind', (tester) async {
    await tester.pumpWidget(_app(eligible: true));
    await tester.pumpAndSettle();

    // The spy always fails. Nothing may remain to collapse later — collapsing
    // is what moves a transaction row under a finger already on its way down.
    expect(_bannerSize(tester).height, 0);
  });

  testWidgets('OFFSTAGE in an IndexedStack: no request while hidden',
      (tester) async {
    // The real shell is an IndexedStack, whose hidden children stay laid out
    // and merely go unpainted. Without the Visibility.of gate this banner would
    // request an ad for a tab the user is not looking at.
    Widget stack(int index) => ProviderScope(
          overrides: [
            bannerEligibilityProvider(AdPlacement.transactionsList)
                .overrideWith((ref) async => true),
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
              body: IndexedStack(
                index: index,
                children: const [
                  Center(child: Text('other tab')),
                  QirshAdBanner(placement: AdPlacement.transactionsList),
                ],
              ),
            ),
          ),
        );

    await tester.pumpWidget(stack(0)); // banner is the hidden child
    await tester.pumpAndSettle();
    expect(_SpyLoader.loadCalls, 0,
        reason: 'a background tab must never request an ad');

    await tester.pumpWidget(stack(1)); // now the visible child
    await tester.pumpAndSettle();
    expect(_SpyLoader.loadCalls, 1);
  });

  testWidgets('an open modal suppresses the banner', (tester) async {
    // AdWidget is a platform view; this app already found that platform views
    // bleed over Flutter sheets. An ad drawn on top of app content is a
    // placement-policy violation, not a cosmetic bug.
    modalRouteOpen.value = true;
    await tester.pumpWidget(_app(eligible: true));
    await tester.pumpAndSettle();

    expect(_bannerSize(tester).height, 0);
    expect(_SpyLoader.loadCalls, 0);

    modalRouteOpen.value = false;
    await tester.pumpAndSettle();
    expect(_SpyLoader.loadCalls, 1, reason: 'and returns when the sheet closes');
  });

  testWidgets('a narrow slot is never asked for an ad', (tester) async {
    await tester.pumpWidget(_app(
      eligible: true,
      wrapper: const SizedBox(
        width: 200,
        child: QirshAdBanner(placement: AdPlacement.transactionsList),
      ),
    ));
    await tester.pumpAndSettle();

    // 200 is below the narrowest standard banner; a slot narrower than its
    // creative either clips it or scrolls it sideways.
    expect(_SpyLoader.resolveCalls, 0);
    expect(_SpyLoader.loadCalls, 0);
  });

  testWidgets('unmounting disposes without leaking a request', (tester) async {
    await tester.pumpWidget(_app(eligible: true));
    await tester.pumpAndSettle();
    expect(_SpyLoader.loadCalls, 1);

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pumpAndSettle();
    expect(_SpyLoader.loadCalls, 1, reason: 'no request on the way out');
  });

  for (final locale in const [Locale('ar'), Locale('en')]) {
    testWidgets('renders in ${locale.languageCode} without overflow',
        (tester) async {
      await tester.pumpWidget(_app(eligible: false, locale: locale));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('survives a large text scale', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
        child: _app(eligible: false),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
