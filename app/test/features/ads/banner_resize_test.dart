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

/// A BANNER MUST NOT OUTLIVE THE WIDTH IT WAS REQUESTED FOR.
///
/// An anchored adaptive banner's height comes from the width at REQUEST time,
/// and the creative that arrives is sized for it. Nothing re-adapts afterwards.
/// The widget used to consult `LayoutBuilder` only while it had no controller,
/// so once an ad existed the available width was never looked at again: an ad
/// requested in landscape kept its landscape dimensions in portrait, inside a
/// box Flutter had already narrowed around it.
///
/// Rotation is the obvious way in. Any resize does it — a keyboard, a split
/// view, a parent that changes its constraints.

final _silentAnalytics = BannerAdsAnalytics(
  cloudProcessingEnabled: () async => false,
  metrics: MetricsClient(),
);

class _SpyLoader implements BannerAdLoader {
  static final List<int> requestedWidths = [];
  static int disposeCalls = 0;
  static void reset() {
    requestedWidths.clear();
    disposeCalls = 0;
  }

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
    requestedWidths.add(widthPx);
    return false;
  }

  @override
  void dispose() => disposeCalls++;
}

/// ONE tree, with a mutable width.
///
/// Re-pumping a fresh `ProviderScope` per width looks equivalent and is not:
/// it rebuilds the eligibility override from scratch, which resolves through
/// `null` again, and the widget correctly tears the ad down for that — so every
/// "resize" disposed even when the width never moved. The width has to change
/// underneath a tree that stays put.
final _width = ValueNotifier<double>(390);

Widget _app() {
  return ProviderScope(
    overrides: [
      bannerEligibilityProvider(AdPlacement.reports)
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
        body: Align(
          alignment: Alignment.topCenter,
          child: ValueListenableBuilder<double>(
            valueListenable: _width,
            builder: (context, w, _) => SizedBox(
              width: w,
              child: const QirshAdBanner(placement: AdPlacement.reports),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  /// Mounts the banner at [width] with a CLEAN counter.
  ///
  /// The reset cannot live in `setUp`: the previous test's tree is not torn
  /// down until the next `pumpWidget` replaces it, so its dispose landed on the
  /// next test's counter and every test after the first read one phantom
  /// disposal. Clearing the tree first, then the counters, then mounting, is
  /// what makes each test independent.
  Future<void> boot(WidgetTester tester, {double width = 390}) async {
    await tester.pumpWidget(const SizedBox.shrink());
    _SpyLoader.reset();
    BannerAdController.resetThrottleForTest();
    _width.value = width;
    await tester.pumpWidget(_app());
    await _settle(tester);
  }

  /// Change the width under the live tree and let the frames land.
  Future<void> resizeTo(WidgetTester tester, double w) async {
    _width.value = w;
    await _settle(tester);
    await _settle(tester);
  }

  testWidgets('narrowing drops the creative requested for the wider box',
      (tester) async {
    // Landscape-ish, then portrait-ish. Before the fix the controller survived
    // untouched and the widget went on rendering an ad sized for 720.
    await boot(tester, width: 720);
    expect(_SpyLoader.requestedWidths, [720]);
    expect(_SpyLoader.disposeCalls, 0);

    await resizeTo(tester, 390);

    expect(_SpyLoader.disposeCalls, 1,
        reason: 'the ad was requested for a box that no longer exists');
  });

  testWidgets(
      'widening drops it too — the mismatch is what matters, '
      'not the direction', (tester) async {
    await boot(tester);
    expect(_SpyLoader.requestedWidths, [390]);

    await resizeTo(tester, 720);

    expect(_SpyLoader.disposeCalls, 1);
  });

  testWidgets('the replacement is requested at the NEW width', (tester) async {
    await boot(tester, width: 720);
    await resizeTo(tester, 390);

    // The re-request that follows a resize meets the ordinary 30-second
    // throttle, which is correct — a resize is not a licence to spend — and
    // today a refused request leaves a terminally failed controller until the
    // widget is rebuilt from scratch. That second part is a separate defect
    // with its own fix; here the question is only WHICH WIDTH the replacement
    // asks for, so this stands where the user would be on their next visit.
    BannerAdController.resetThrottleForTest();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(_app());
    await _settle(tester);
    await _settle(tester);

    expect(_SpyLoader.requestedWidths.last, 390,
        reason: 'the replacement carries the width that is actually there');
    expect(_SpyLoader.requestedWidths.first, 720);
  });

  testWidgets('a width that does not change buys nothing extra',
      (tester) async {
    // The guard must not churn on ordinary rebuilds, or every frame would cost
    // a dispose and a throttled request.
    await boot(tester);
    for (var i = 0; i < 5; i++) {
      await resizeTo(tester, 390);
    }
    expect(_SpyLoader.requestedWidths, [390]);
    expect(_SpyLoader.disposeCalls, 0);
  });

  testWidgets('a sub-pixel width change is not a resize', (tester) async {
    // Constraints arrive as doubles and can wobble by fractions during layout.
    // The comparison is on whole pixels for that reason.
    await boot(tester);
    await resizeTo(tester, 390.4);
    expect(_SpyLoader.disposeCalls, 0);
    expect(_SpyLoader.requestedWidths, [390]);
  });
}
