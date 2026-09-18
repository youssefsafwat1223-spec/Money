import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backend/metrics_client.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/data/db/planning_cutover.dart';
import 'package:money_companion/domain/entities/bill_entity.dart';
import 'package:money_companion/domain/entities/goal_entity.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/goals/goals_providers.dart';
import 'package:money_companion/features/goals/goals_screen.dart';
import 'package:money_companion/domain/entities/category_entity.dart';
import 'package:money_companion/features/ads/interstitial_cooldown.dart';
import 'package:money_companion/features/common/category_catalog.dart';
import 'package:money_companion/features/dashboard/dashboard_providers.dart'
    show CategorySlice;
import 'package:money_companion/features/reports/reports_providers.dart';
import 'package:money_companion/features/reports/reports_screen.dart';
import 'package:money_companion/features/settings/settings_providers.dart';
import 'package:money_companion/features/subscriptions/subscriptions_providers.dart';
import 'package:money_companion/features/subscriptions/subscriptions_screen.dart';
import 'package:money_companion/features/achievements/achievements_providers.dart';
import 'package:money_companion/features/achievements/achievements_screen.dart';
import 'package:money_companion/features/ads/ad_placement.dart';
import 'package:money_companion/features/ads/banner_ad_controller.dart';
import 'package:money_companion/features/ads/banner_ads_analytics.dart';
import 'package:money_companion/features/ads/banner_ads_providers.dart';
import 'package:money_companion/features/ads/qirsh_ad_banner.dart';
import 'package:money_companion/features/report_ads/report_entitlement.dart';
import 'package:money_companion/l10n/app_localizations.dart';

/// THE BANNER, ON EACH APPROVED SCREEN.
///
/// One group per placement. Every group answers the same four questions, and
/// they are the ones the ad-surface contract actually depends on:
///
///   * exactly ONE banner is mounted, never two;
///   * a rebuild or a tab switch does not buy a second ad;
///   * the empty and error states carry NO ad;
///   * the banner is a DIRECT child of the scroll view, so sliver laziness
///     applies — verified in `banner_placement_mechanics_test.dart` and relied
///     on here.
///
/// The screens are driven through their own view providers, so no database is
/// opened and the assertions are about placement rather than data.

final _silentAnalytics = BannerAdsAnalytics(
  cloudProcessingEnabled: () async => false,
  metrics: MetricsClient(),
);

class _SpyLoader implements BannerAdLoader {
  static int loadCalls = 0;
  static void reset() => loadCalls = 0;

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
  void dispose() {}
}

Widget _host(Widget screen, List<Override> overrides) {
  return ProviderScope(
    overrides: [
      for (final p in AdPlacement.values)
        bannerEligibilityProvider(p).overrideWith((ref) async => true),
      bannerAdLoaderFactoryProvider.overrideWithValue(_SpyLoader.new),
      bannerAdsAnalyticsProvider.overrideWithValue(_silentAnalytics),
      ...overrides,
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
      home: screen,
    ),
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

/// Scrolls the screen's primary list to the bottom, where the banner lives.
/// Sliver laziness means it is not mounted until something reaches it.
Future<void> _scrollToBottom(WidgetTester tester) async {
  final scrollable = find.byType(Scrollable).first;
  for (var i = 0; i < 6; i++) {
    await tester.drag(scrollable, const Offset(0, -900));
    await _settle(tester);
  }
}

AchievementsView _achievementsView({int badges = 8}) => AchievementsView(
      achievements: [
        for (var i = 0; i < badges; i++)
          AchievementEntity(
            id: 'a$i',
            key: 'first_transaction',
            nameAr: 'إنجاز $i',
            progress: 1,
            unlockedAt: i.isEven ? DateTime.utc(2026, 1, 1) : null,
          ),
      ],
      xpLevel: const XpLevelEntity(
          id: 'x', totalXp: 120, level: 1, levelKey: 'beginner'),
      streak: StreakEntity(
        id: 's',
        currentStreak: 3,
        longestStreak: 9,
        lastActiveDate: DateTime.utc(2026, 9, 18),
        freezesAvailable: 1,
      ),
    );

List<GoalEntity> _goals(int count) => [
      for (var i = 0; i < count; i++)
        GoalEntity(
          id: 'g$i',
          name: 'هدف $i',
          currency: 'SAR',
          targetMoney: Money.parse('5000', 'SAR'),
          savedMoney: Money.parse('1200', 'SAR'),
          lastNotifiedSavedMoney: Money(0, 'SAR'),
          vaultSkin: 'summer_trip',
          status: 'active',
          createdAt: DateTime.utc(2026, 1, 1),
        ),
    ];

/// GoalsScreen sits behind `PlanningRepairGate`, which reads the cutover
/// coordinator and therefore the database. A canonical stub keeps the test
/// about placement.
class _CanonicalCutover implements PlanningCutoverCoordinator {
  @override
  PlanningCutoverState state() => PlanningCutoverState.canonical;
}

UserSettingsEntity _settings() => const UserSettingsEntity(
      id: 'u1',
      country: 'SA',
      currency: 'SAR',
      language: 'ar',
      theme: 'dark',
      inputMethod: 'manual',
      notificationsJson: '{}',
      privacyModeEnabled: false,
    );

void main() {
  setUp(() {
    _SpyLoader.reset();
    BannerAdController.resetThrottleForTest();
    InterstitialCooldown.resetForTest();
  });

  group('achievements', () {
    testWidgets('mounts exactly one banner, below the badge grid',
        (tester) async {
      await tester.pumpWidget(_host(
        const AchievementsScreen(),
        [
          achievementsViewProvider
              .overrideWith((ref) async => _achievementsView())
        ],
      ));
      await _settle(tester);

      // Sliver laziness: nothing yet, because the slot is below the grid.
      expect(_SpyLoader.loadCalls, 0,
          reason:
              'the banner sits below the grid and must not load on arrival');

      await _scrollToBottom(tester);
      expect(find.byType(QirshAdBanner), findsOneWidget);
      expect(_SpyLoader.loadCalls, 1);
    });

    testWidgets('a rebuild does not buy a second ad', (tester) async {
      await tester.pumpWidget(_host(
        const AchievementsScreen(),
        [
          achievementsViewProvider
              .overrideWith((ref) async => _achievementsView())
        ],
      ));
      await _settle(tester);
      await _scrollToBottom(tester);
      expect(_SpyLoader.loadCalls, 1);

      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(_SpyLoader.loadCalls, 1);
      expect(find.byType(QirshAdBanner), findsOneWidget);
    });

    testWidgets('the ERROR state carries no ad', (tester) async {
      await tester.pumpWidget(_host(
        const AchievementsScreen(),
        [
          achievementsViewProvider
              .overrideWith((ref) async => throw StateError('boom')),
        ],
      ));
      await _settle(tester);

      expect(find.byType(QirshAdBanner), findsNothing);
      expect(_SpyLoader.loadCalls, 0);
    });

    testWidgets('an EMPTY badge list carries no ad', (tester) async {
      await tester.pumpWidget(_host(
        const AchievementsScreen(),
        [
          achievementsViewProvider
              .overrideWith((ref) async => _achievementsView(badges: 0)),
        ],
      ));
      await _settle(tester);
      await _scrollToBottom(tester);

      expect(find.byType(QirshAdBanner), findsNothing,
          reason: 'an ad alone on an empty screen reads as the content');
      expect(_SpyLoader.loadCalls, 0);
    });
  });

  group('goals', () {
    List<Override> deps(int count) => [
          planningCutoverCoordinatorProvider
              .overrideWithValue(_CanonicalCutover()),
          baseCurrencyProvider.overrideWith((ref) async => 'SAR'),
          goalsListProvider.overrideWith((ref) async => _goals(count)),
        ];

    testWidgets('mounts exactly one banner, below the goal cards',
        (tester) async {
      await tester.pumpWidget(_host(const GoalsScreen(), deps(4)));
      await _settle(tester);
      await _scrollToBottom(tester);

      expect(find.byType(QirshAdBanner), findsOneWidget);
      expect(_SpyLoader.loadCalls, 1);
    });

    testWidgets('a single goal carries no ad', (tester) async {
      // One goal makes the ad the second thing on a nearly empty screen.
      await tester.pumpWidget(_host(const GoalsScreen(), deps(1)));
      await _settle(tester);
      await _scrollToBottom(tester);

      expect(find.byType(QirshAdBanner), findsNothing);
      expect(_SpyLoader.loadCalls, 0);
    });

    testWidgets('the EMPTY state carries no ad', (tester) async {
      // That branch is a create-your-first-goal prompt and a separate ListView.
      await tester.pumpWidget(_host(const GoalsScreen(), deps(0)));
      await _settle(tester);
      await _scrollToBottom(tester);

      expect(find.byType(QirshAdBanner), findsNothing);
      expect(_SpyLoader.loadCalls, 0);
    });

    testWidgets('the ERROR state carries no ad', (tester) async {
      await tester.pumpWidget(_host(const GoalsScreen(), [
        planningCutoverCoordinatorProvider
            .overrideWithValue(_CanonicalCutover()),
        baseCurrencyProvider.overrideWith((ref) async => 'SAR'),
        goalsListProvider.overrideWith((ref) async => throw StateError('boom')),
      ]));
      await _settle(tester);

      expect(find.byType(QirshAdBanner), findsNothing);
      expect(_SpyLoader.loadCalls, 0);
    });

    testWidgets('a rebuild does not buy a second ad', (tester) async {
      await tester.pumpWidget(_host(const GoalsScreen(), deps(4)));
      await _settle(tester);
      await _scrollToBottom(tester);
      expect(_SpyLoader.loadCalls, 1);

      await _settle(tester);
      expect(_SpyLoader.loadCalls, 1);
      expect(find.byType(QirshAdBanner), findsOneWidget);
    });
  });

  group('subscriptions', () {
    List<BillEntity> bills(int count) => [
          for (var i = 0; i < count; i++)
            BillEntity(
              id: 'b$i',
              name: 'اشتراك $i',
              amountMoney: Money.parse('49', 'SAR'),
              currency: 'SAR',
              type: BillType.subscription,
              frequency: BillFrequency.monthly,
              nextDueDate: DateTime.utc(2026, 10, 1),
              reminderOn: true,
              isConfirmed: true,
              createdAt: DateTime.utc(2026, 1, 1),
            ),
        ];

    List<Override> deps(int count) => [
          baseCurrencyProvider.overrideWith((ref) async => 'SAR'),
          billsScopeAccountProvider.overrideWith((ref) async => null),
          savedBillsProvider.overrideWith((ref) async => bills(count)),
          subscriptionsProvider.overrideWith((ref) async => []),
        ];

    testWidgets('mounts ONE banner in the header, above the tab bar',
        (tester) async {
      // The header sliver is not lazy, so unlike the list placements this one
      // is expected to request on arrival — it is on screen on arrival.
      await tester.pumpWidget(_host(const SubscriptionsScreen(), deps(3)));
      await _settle(tester);

      expect(find.byType(QirshAdBanner), findsOneWidget);
      expect(_SpyLoader.loadCalls, 1);
    });

    testWidgets('switching tabs does not buy a second ad', (tester) async {
      await tester.pumpWidget(_host(const SubscriptionsScreen(), deps(3)));
      await _settle(tester);
      expect(_SpyLoader.loadCalls, 1);

      final controller =
          DefaultTabController.of(tester.element(find.byType(TabBarView)));
      controller.animateTo(1);
      await _settle(tester);
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(QirshAdBanner), findsOneWidget,
          reason: 'one shared instance, not one per tab');
      expect(_SpyLoader.loadCalls, 1);
    });

    testWidgets('an EMPTY bills screen carries no ad', (tester) async {
      await tester.pumpWidget(_host(const SubscriptionsScreen(), deps(0)));
      await _settle(tester);

      expect(find.byType(QirshAdBanner), findsNothing);
      expect(_SpyLoader.loadCalls, 0);
    });

    testWidgets('the ERROR state carries no ad', (tester) async {
      await tester.pumpWidget(_host(const SubscriptionsScreen(), [
        baseCurrencyProvider.overrideWith((ref) async => 'SAR'),
        billsScopeAccountProvider.overrideWith((ref) async => null),
        savedBillsProvider
            .overrideWith((ref) async => throw StateError('boom')),
        subscriptionsProvider.overrideWith((ref) async => []),
      ]));
      await _settle(tester);

      expect(find.byType(QirshAdBanner), findsNothing);
      expect(_SpyLoader.loadCalls, 0);
    });
  });

  group('reports', () {
    ReportSection section({int categories = 3}) => ReportSection(
          total: Money.parse('2400', 'SAR'),
          prevTotal: Money.parse('2000', 'SAR'),
          refunds: Money(0, 'SAR'),
          topCategories: [
            for (var i = 0; i < categories; i++)
              CategorySlice(
                category: CategoryView(CategoryEntity(
                  id: 'c$i',
                  key: 'restaurants',
                  nameAr: 'مطاعم',
                  icon: 'utensils-crossed',
                  color: '#FF7043',
                  isIncome: false,
                  sort: i,
                )),
                total: Money.parse('800', 'SAR'),
                percent: 0.33,
              ),
          ],
          topMerchants: const [],
          dailySpend: const [],
          anomaly: null,
        );

    List<Override> deps({int categories = 3}) => [
          baseCurrencyProvider.overrideWith((ref) async => 'SAR'),
          userSettingsProvider.overrideWith((ref) async => _settings()),
          reportsProvider.overrideWith((ref) async => ReportsBundle(
                weekly: section(categories: categories),
                monthly: section(categories: categories),
              )),
        ];

    testWidgets('mounts ONE banner in the header', (tester) async {
      await tester.pumpWidget(_host(const ReportsScreen(), deps()));
      await _settle(tester);

      expect(find.byType(QirshAdBanner), findsOneWidget);
      expect(_SpyLoader.loadCalls, 1);
    });

    testWidgets('switching tabs does not buy a second ad', (tester) async {
      await tester.pumpWidget(_host(const ReportsScreen(), deps()));
      await _settle(tester);
      expect(_SpyLoader.loadCalls, 1);

      final controller =
          DefaultTabController.of(tester.element(find.byType(TabBarView)));
      controller.animateTo(2);
      await _settle(tester);
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(QirshAdBanner), findsOneWidget);
      expect(_SpyLoader.loadCalls, 1);
    });

    testWidgets('an EMPTY report carries no ad', (tester) async {
      await tester
          .pumpWidget(_host(const ReportsScreen(), deps(categories: 0)));
      await _settle(tester);

      expect(find.byType(QirshAdBanner), findsNothing);
      expect(_SpyLoader.loadCalls, 0);
    });

    testWidgets('the ERROR state carries no ad', (tester) async {
      await tester.pumpWidget(_host(const ReportsScreen(), [
        baseCurrencyProvider.overrideWith((ref) async => 'SAR'),
        userSettingsProvider.overrideWith((ref) async => _settings()),
        reportsProvider.overrideWith((ref) async => throw StateError('boom')),
      ]));
      await _settle(tester);

      expect(find.byType(QirshAdBanner), findsNothing);
      expect(_SpyLoader.loadCalls, 0);
    });
  });

  // The cooldown lives in `bannerEligibilityProvider`, which the screen tests
  // above override wholesale — so it has to be exercised where it actually is.
  // These drive the REAL provider and override only its inputs.
  group('reports interstitial cooldown', () {
    Future<bool?> resolve() async {
      final container = ProviderContainer(overrides: [
        bannerPlacementEnabledProvider(AdPlacement.reports)
            .overrideWithValue(true),
        bannerEntitlementProvider.overrideWith(
            (ref) async => ReportEntitlementState.verifiedInactive),
        bannerConsentProvider.overrideWith((ref) async => true),
      ]);
      addTearDown(container.dispose);
      return container
          .read(bannerEligibilityProvider(AdPlacement.reports).future);
    }

    test('blocks Reports right after an interstitial', () async {
      InterstitialCooldown.markShown();
      expect(await resolve(), isFalse);
    });

    test('clears once the window has passed', () async {
      var now = DateTime.utc(2026, 9, 19, 12);
      InterstitialCooldown.clock = () => now;
      InterstitialCooldown.markShown();
      now = now.add(InterstitialCooldown.window + const Duration(seconds: 1));
      expect(await resolve(), isTrue);
    });

    test('never blocks another placement', () async {
      // Reports is the only surface with two formats. A global cooldown would
      // silently cost every other placement an ad for two minutes.
      InterstitialCooldown.markShown();
      final container = ProviderContainer(overrides: [
        bannerPlacementEnabledProvider(AdPlacement.goals)
            .overrideWithValue(true),
        bannerEntitlementProvider.overrideWith(
            (ref) async => ReportEntitlementState.verifiedInactive),
        bannerConsentProvider.overrideWith((ref) async => true),
      ]);
      addTearDown(container.dispose);
      expect(
        await container
            .read(bannerEligibilityProvider(AdPlacement.goals).future),
        isTrue,
      );
    });
  });
}
