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
import 'package:money_companion/l10n/app_localizations.dart';

/// PLACEMENT MECHANICS — what the framework actually does, not what a plan
/// assumes it does.
///
/// Every test here exists to check one load-bearing assumption in the banner
/// surface plan (v3) BEFORE any of the five new screens is touched. The
/// assumptions are about Flutter's own behaviour — sliver laziness, `Scrollable`
/// lookup, `ModalRoute.isCurrent`, `NestedScrollView` headers, `TabBarView`
/// mounting — so they are checkable now and cheap to get wrong later.
///
/// `AdWidget` is a platform view and cannot render here, so the loader is faked
/// and every assertion is about REQUESTS and LIFECYCLE. That is the right
/// boundary: everything this app decides happens before the SDK is called.

final _silentAnalytics = BannerAdsAnalytics(
  cloudProcessingEnabled: () async => false,
  metrics: MetricsClient(),
);

class _SpyLoader implements BannerAdLoader {
  static int loadCalls = 0;
  static int disposeCalls = 0;
  static void reset() {
    loadCalls = 0;
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
    loadCalls++;
    return false;
  }

  @override
  void dispose() => disposeCalls++;
}

/// Wraps [child] with every provider the banner needs, with eligibility forced
/// true so the only thing under test is placement mechanics.
Widget _app(Widget child, {Set<AdPlacement>? placements}) {
  return ProviderScope(
    overrides: [
      for (final p in placements ?? {AdPlacement.transactionsList})
        bannerEligibilityProvider(p).overrideWith((ref) async => true),
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
      home: child,
    ),
  );
}

/// One frame plus the microtasks the request chain needs. `pumpAndSettle` is
/// wrong here — the glass treatment in this app never quiesces.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  setUp(() {
    _SpyLoader.reset();
    BannerAdController.resetThrottleForTest();
  });

  // ── 1. Is an eager ListView actually eager? ────────────────────────────────

  group('sliver laziness', () {
    testWidgets(
        'a banner far below the fold in ListView(children:) does NOT request',
        (tester) async {
      // THE assumption plan v3 §A1 rests on: that `ListView(children: [...])`
      // — which is what Dashboard, Goals, Achievements and every Reports and
      // Subscriptions tab body use — builds its banner immediately regardless
      // of viewport, and therefore fires an ad request for a slot the user has
      // not reached.
      //
      // The widget LIST is built eagerly. Whether the widget's ELEMENT is is a
      // different question, and it is the one that decides whether a request
      // happens.
      await tester.pumpWidget(_app(Scaffold(
        body: ListView(
          children: [
            for (var i = 0; i < 20; i++)
              SizedBox(height: 400, child: Text('block $i')),
            const QirshAdBanner(placement: AdPlacement.transactionsList),
          ],
        ),
      )));
      await _settle(tester);
      expect(_SpyLoader.loadCalls, 0,
          reason: 'a slot 8000px below the fold must not buy an ad');
    });

    testWidgets('...and it DOES request once scrolled to', (tester) async {
      await tester.pumpWidget(_app(Scaffold(
        body: ListView(
          children: [
            for (var i = 0; i < 20; i++)
              SizedBox(height: 400, child: Text('block $i')),
            const QirshAdBanner(placement: AdPlacement.transactionsList),
          ],
        ),
      )));
      await _settle(tester);
      await tester.drag(find.text('block 0'), const Offset(0, -7600));
      await _settle(tester);
      expect(_SpyLoader.loadCalls, 1,
          reason: 'reaching the slot is what buys the ad');
    });

    testWidgets('a banner INSIDE a materialised list child is NOT protected',
        (tester) async {
      // The counterpart, and the one that actually bites. Sliver laziness is
      // per direct child. A banner nested inside a tall `Column` that is itself
      // one list child inherits that child's fate: the moment any part of the
      // Column is in the cache area, the WHOLE Column builds — including a
      // banner 2000px further down inside it.
      await tester.pumpWidget(_app(Scaffold(
        body: ListView(
          children: [
            Column(
              children: [
                for (var i = 0; i < 6; i++)
                  SizedBox(height: 400, child: Text('row $i')),
                const QirshAdBanner(placement: AdPlacement.transactionsList),
              ],
            ),
          ],
        ),
      )));
      await _settle(tester);
      expect(_SpyLoader.loadCalls, 1,
          reason: 'nesting defeats sliver laziness — this is the real hazard');
    });
  });

  // ── 2. Does scrolling tear the ad down? ───────────────────────────────────

  group('scroll lifecycle', () {
    testWidgets('scrolling a requested banner out of view DISPOSES it',
        (tester) async {
      await tester.pumpWidget(_app(Scaffold(
        body: ListView(
          children: [
            const QirshAdBanner(placement: AdPlacement.transactionsList),
            for (var i = 0; i < 20; i++)
              SizedBox(height: 400, child: Text('block $i')),
          ],
        ),
      )));
      await _settle(tester);
      expect(_SpyLoader.loadCalls, 1);

      await tester.drag(find.text('block 0'), const Offset(0, -3000));
      await _settle(tester);

      expect(_SpyLoader.disposeCalls, 1,
          reason: 'the sliver unmounts the element, which disposes the State');
    });

    testWidgets('scrolling BACK cannot re-buy an ad — the throttle refuses',
        (tester) async {
      // The consequence of the test above, and the reason "never tear down on
      // scroll" cannot be implemented inside the widget: the framework, not the
      // widget, decides when the element dies. On return a fresh State requests
      // again and the 30-second per-placement throttle — which is static and
      // survives the unmount by design — refuses it. The slot stays empty.
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(_app(Scaffold(
        body: ListView(
          controller: controller,
          children: [
            const SizedBox(height: 200, child: Text('lead')),
            const QirshAdBanner(placement: AdPlacement.transactionsList),
            for (var i = 0; i < 20; i++)
              SizedBox(height: 400, child: Text('block $i')),
          ],
        ),
      )));
      await _settle(tester);
      expect(_SpyLoader.loadCalls, 1);

      controller.jumpTo(3000);
      await _settle(tester);
      expect(_SpyLoader.disposeCalls, 1);

      controller.jumpTo(0);
      await _settle(tester);

      expect(find.byType(QirshAdBanner), findsOneWidget,
          reason: 'the widget is back on screen...');
      expect(_SpyLoader.loadCalls, 1,
          reason: '...but the second request was throttled, not served');
    });
  });

  // ── 3. Scrollable lookup, for the proximity rule ──────────────────────────

  group('Scrollable lookup', () {
    testWidgets('a zero-height widget in a list still has a position',
        (tester) async {
      // The deadlock question. The banner renders `SizedBox.shrink()` until it
      // loads, so a VISIBILITY test can never pass. A POSITION test can: a
      // zero-height box still has a global offset, and a `Scrollable` ancestor
      // to measure it against.
      final key = GlobalKey();
      await tester.pumpWidget(_app(Scaffold(
        body: ListView(
          children: [
            const SizedBox(height: 300),
            SizedBox.shrink(key: key),
            const SizedBox(height: 2000),
          ],
        ),
      )));
      await tester.pump();

      final ctx = key.currentContext!;
      expect(Scrollable.maybeOf(ctx), isNotNull);
      final box = ctx.findRenderObject()! as RenderBox;
      expect(box.size.height, 0);
      final dy = box.localToGlobal(Offset.zero).dy;
      expect(dy.isFinite, isTrue);
      expect(dy, greaterThan(0));
    });

    testWidgets('outside a Scrollable the lookup is null, not a hang',
        (tester) async {
      // The other half of the deadlock guard: the two header placements are not
      // inside the inner scrollable, and "no Scrollable ⇒ near by definition"
      // must be a reachable branch rather than a theoretical one.
      final key = GlobalKey();
      await tester.pumpWidget(_app(Scaffold(
        body: Align(child: SizedBox.shrink(key: key)),
      )));
      await tester.pump();
      expect(Scrollable.maybeOf(key.currentContext!), isNull);
    });
  });

  // ── 4. ModalRoute.isCurrent, for the Reports export flow ──────────────────

  group('route coverage', () {
    testWidgets('pushing a full-screen route tears the banner down, and pop '
        'does NOT bring it back', (tester) async {
      // Plan v3 §C1 claims `showReportConfigPage` — which pushes a
      // `MaterialPageRoute` — already suppresses the reports banner through the
      // existing route gate. First half verified here.
      //
      // The second half is the finding: the pop does not restore it, because
      // the re-request meets the throttle.
      await tester.pumpWidget(_app(Scaffold(
        body: Builder(
          builder: (context) => Column(
            children: [
              const QirshAdBanner(placement: AdPlacement.transactionsList),
              TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (inner) => Scaffold(
                      body: TextButton(
                        onPressed: () => Navigator.of(inner).pop(),
                        child: const Text('done'),
                      ),
                    ),
                  ),
                ),
                child: const Text('export'),
              ),
            ],
          ),
        ),
      )));
      await _settle(tester);
      expect(_SpyLoader.loadCalls, 1);

      await tester.tap(find.text('export'));
      await _settle(tester);
      await tester.pump(const Duration(milliseconds: 400));
      expect(_SpyLoader.disposeCalls, 1,
          reason: 'ModalRoute.isCurrent is false under a pushed route');

      await tester.tap(find.text('done'));
      await _settle(tester);
      await tester.pump(const Duration(milliseconds: 400));
      expect(_SpyLoader.loadCalls, 1,
          reason: 'the re-request on return is throttled, not served');
    });
  });

  // ── 5. NestedScrollView header + TabBarView ───────────────────────────────

  group('NestedScrollView header placement', () {
    Widget tabbedScreen({required bool bannerInHeader}) {
      return DefaultTabController(
        length: 2,
        child: Scaffold(
          body: NestedScrollView(
            headerSliverBuilder: (context, _) => [
              SliverToBoxAdapter(
                child: Column(
                  children: [
                    const SizedBox(height: 120, child: Text('header card')),
                    if (bannerInHeader)
                      const QirshAdBanner(
                          placement: AdPlacement.transactionsList),
                  ],
                ),
              ),
              const SliverPersistentHeader(
                pinned: true,
                delegate: _TabBarDelegate(),
              ),
            ],
            body: TabBarView(
              children: [
                ListView(children: [
                  if (!bannerInHeader)
                    const QirshAdBanner(
                        placement: AdPlacement.transactionsList),
                  const SizedBox(height: 600, child: Text('tab A body')),
                ]),
                ListView(children: [
                  if (!bannerInHeader)
                    const QirshAdBanner(
                        placement: AdPlacement.transactionsList),
                  const SizedBox(height: 600, child: Text('tab B body')),
                ]),
              ],
            ),
          ),
        ),
      );
    }

    testWidgets('a header banner is ONE instance and survives a tab switch',
        (tester) async {
      await tester.pumpWidget(_app(tabbedScreen(bannerInHeader: true)));
      await _settle(tester);
      expect(find.byType(QirshAdBanner), findsOneWidget);
      expect(_SpyLoader.loadCalls, 1);

      await tester.tap(find.text('Tab 2'));
      await _settle(tester);
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(QirshAdBanner), findsOneWidget);
      expect(_SpyLoader.loadCalls, 1, reason: 'no second request on tab switch');
      expect(_SpyLoader.disposeCalls, 0, reason: 'the header did not rebuild it');
    });

    testWidgets('a header banner survives scrolling the header away',
        (tester) async {
      // The header sits in a `SliverToBoxAdapter`, which is not lazy — but it
      // can still be unmounted once it is fully past the cache area. If it
      // were, the header placement would inherit the same lose-it-on-scroll
      // problem as an in-list one, and the plan's choice of the header would
      // buy nothing.
      await tester.pumpWidget(_app(tabbedScreen(bannerInHeader: true)));
      await _settle(tester);
      expect(_SpyLoader.loadCalls, 1);

      await tester.drag(find.text('tab A body'), const Offset(0, -500));
      await _settle(tester);
      await tester.drag(find.text('tab A body'), const Offset(0, -500));
      await _settle(tester);

      expect(_SpyLoader.disposeCalls, 0,
          reason: 'the NestedScrollView header holds its child while pinned '
              'slivers keep the outer sliver in the tree');
      expect(_SpyLoader.loadCalls, 1);
    });

    testWidgets('a per-tab banner is a DEAD SLOT on the second tab',
        (tester) async {
      // Why v3 §B puts the banner in the header for Reports and Subscriptions
      // rather than in each tab. The second tab requests, meets the 30-second
      // static per-placement throttle, and renders nothing for the rest of the
      // visit.
      await tester.pumpWidget(_app(tabbedScreen(bannerInHeader: false)));
      await _settle(tester);
      expect(_SpyLoader.loadCalls, 1);

      await tester.tap(find.text('Tab 2'));
      await _settle(tester);
      await tester.pump(const Duration(milliseconds: 400));

      expect(_SpyLoader.loadCalls, 1,
          reason: 'tab B asked and was refused — an empty slot, not an ad');
    });
  });

  // ── 6. The gap between deciding and requesting ────────────────────────────

  testWidgets('a gate that closes between build and the post-frame callback '
      'cancels the request', (tester) async {
    // `build` decides and a post-frame callback acts, with a frame boundary
    // between them. An earlier draft reported this as unproven because
    // `tester.pump()` runs post-frame callbacks inside the same frame, leaving
    // no window.
    //
    // There IS a window, and this is how to open it. The gate must close in the
    // SAME frame in which the banner decides to request — not the frame before,
    // which the build-time gate already catches and which would let this test
    // pass for the wrong reason.
    //
    // So the closer watches the very provider whose resolution unblocks the
    // request. On the frame where eligibility turns true: the parent rebuilds
    // first and registers its callback first, the banner then builds and
    // schedules `_maybeRequest`, and post-frame callbacks run in registration
    // order. The gate shuts between the decision and the act, exactly once,
    // deterministically.
    addTearDown(() => modalRouteOpen.value = false);
    await tester.pumpWidget(_app(Scaffold(
      body: Consumer(
        builder: (context, ref, _) {
          final eligible = ref
              .watch(bannerEligibilityProvider(AdPlacement.transactionsList))
              .valueOrNull;
          if (eligible == true) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              modalRouteOpen.value = true;
            });
          }
          return const QirshAdBanner(placement: AdPlacement.transactionsList);
        },
      ),
    )));
    await _settle(tester);

    expect(_SpyLoader.loadCalls, 0,
        reason: 'the sheet opened before the request was issued');
  });

  // ── 7. Rebuild does not duplicate ─────────────────────────────────────────

  testWidgets('a parent rebuild does not buy a second ad', (tester) async {
    final notifier = ValueNotifier<int>(0);
    addTearDown(notifier.dispose);
    await tester.pumpWidget(_app(Scaffold(
      body: ValueListenableBuilder<int>(
        valueListenable: notifier,
        builder: (context, v, _) => Column(
          children: [
            Text('rebuild $v'),
            const QirshAdBanner(placement: AdPlacement.transactionsList),
          ],
        ),
      ),
    )));
    await _settle(tester);
    expect(_SpyLoader.loadCalls, 1);

    for (var i = 1; i <= 5; i++) {
      notifier.value = i;
      await _settle(tester);
    }
    expect(_SpyLoader.loadCalls, 1);
    expect(_SpyLoader.disposeCalls, 0);
  });
}

class _TabBarDelegate extends SliverPersistentHeaderDelegate {
  const _TabBarDelegate();

  @override
  double get minExtent => 64;
  @override
  double get maxExtent => 64;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlaps) {
    return Container(
      color: const Color(0xFF101010),
      height: 64,
      child: const TabBar(tabs: [Tab(text: 'Tab 1'), Tab(text: 'Tab 2')]),
    );
  }

  @override
  bool shouldRebuild(covariant SliverPersistentHeaderDelegate old) => false;
}
