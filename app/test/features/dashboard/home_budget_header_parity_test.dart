import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/widgets/calm_page_header.dart';
import 'package:money_companion/core/theme/widgets/qirsh_visuals.dart';
import 'package:money_companion/core/theme/widgets/ring_progress.dart';
import 'package:money_companion/data/db/planning_cutover.dart';
import 'package:money_companion/domain/entities/budget_entity.dart';
import 'package:money_companion/domain/entities/category_entity.dart';
import 'package:money_companion/domain/entities/engagement_entities.dart';
import 'package:money_companion/domain/entities/goal_entity.dart';
import 'package:money_companion/domain/entities/report_models.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/finance/money_format.dart';
import 'package:money_companion/features/budgets/budgets_providers.dart';
import 'package:money_companion/features/budgets/budgets_screen.dart';
import 'package:money_companion/features/ads/ad_placement.dart';
import 'package:money_companion/features/ads/banner_ads_providers.dart';
import 'package:money_companion/features/common/category_catalog.dart';
import 'package:money_companion/features/dashboard/widgets/daily_spend_card.dart';
import 'package:money_companion/features/goals/goals_providers.dart';
import 'package:money_companion/features/goals/goals_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

final _now = DateTime.now();
final _today = DateUtils.dateOnly(_now);
final _catalog = CategoryCatalog(const [
  CategoryEntity(
      id: 'groceries',
      key: 'groceries',
      nameAr: 'بقالة',
      icon: 'shopping-cart',
      color: '#31D0AA',
      isIncome: false,
      sort: 1)
]);

Future<void> _pump(WidgetTester tester, Widget child,
    {String language = 'en',
    bool dark = false,
    List<Override> overrides = const []}) async {
  tester.view.physicalSize = const Size(375, 667);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.runAsync(() async {
    final loader = FontLoader('Vazirmatn');
    for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      loader.addFont(rootBundle.load('assets/fonts/Vazirmatn-$weight.ttf'));
    }
    await loader.load();
  });
  await tester.pumpWidget(ProviderScope(
      overrides: overrides,
      child: MaterialApp(
          theme: dark ? AppTheme.dark : AppTheme.light,
          locale: Locale(language),
          supportedLocales: AppL10n.supportedLocales,
          localizationsDelegates: AppL10n.localizationsDelegates,
          home: child)));
  await tester.pumpAndSettle();
}

TransactionEntity _tx(String id, int amount, {bool income = false}) =>
    TransactionEntity(
        id: id,
        amountMoney: Money(amount, 'KWD'),
        currency: 'KWD',
        type: income
            ? TransactionTypeEntity.income
            : TransactionTypeEntity.payment,
        source: TransactionSourceEntity.bank,
        occurredAt: _today,
        rawMessage: 'Synthetic message',
        rawMerchant: id,
        categoryId: 'groceries',
        parseConfidence: 1,
        status: TransactionStatus.confirmed,
        createdAt: _now,
        updatedAt: _now);

Widget _daily(
        {Money? limit,
        bool privacy = false,
        Money? available,
        void Function(TransactionEntity)? onTap}) =>
    Scaffold(
        body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: DailySpendCard(
              todaySpend: Money(12345, 'KWD'),
              dailyBudgetLimit: limit,
              averageSevenDays: Money(8765, 'KWD'),
              availableToday: available,
              todayVsYesterday: null,
              todayTransactions: [
                _tx('Debit merchant', 11111),
                _tx('Income must stay excluded', 900000, income: true)
              ],
              todayIsTruncated: false,
              catalog: _catalog,
              currencyLabel: 'KWD',
              privacyMode: privacy,
              onTransactionTap: onTap,
              lastSevenDays: [
                for (var i = 6; i >= 0; i--)
                  DailySpend(
                      day: _today.subtract(Duration(days: i)),
                      total: Money(1000 + i, 'KWD'))
              ],
            )));

GoalEntity _goal(String id, String currency, int saved, int target,
        {String status = 'active'}) =>
    GoalEntity(
        id: id,
        name: id,
        currency: currency,
        savedMoney: Money(saved, currency),
        targetMoney: Money(target, currency),
        lastNotifiedSavedMoney: Money.zero(currency),
        vaultSkin: 'glass',
        status: status,
        createdAt: _now);

BudgetProgressEntry _entry(String id, String currency, int spent, int limit,
    {BudgetHealth health = BudgetHealth.safe, int endDays = 8}) {
  final budget = BudgetEntity(
      id: id,
      categoryId: 'groceries',
      currency: currency,
      amountMoney: Money(limit, currency),
      lastNotifiedSpentMoney: Money.zero(currency),
      period: BudgetPeriod.monthly,
      startDate: _today,
      isActive: true,
      lastNotifiedPeriodStart: _today);
  return BudgetProgressEntry(
      budget: budget,
      spent: Money(spent, currency),
      remaining: Money(limit - spent, currency),
      ratio: spent / limit,
      health: health,
      periodStart: _today.subtract(const Duration(days: 20)),
      periodEnd: _today.add(Duration(days: endDays)));
}

Future<AppL10n> _budgets(WidgetTester tester,
    {required bool goals,
    String language = 'en',
    bool dark = false,
    bool mixedEnds = false}) async {
  final view = BudgetsView(
      snapshot: BudgetProgressSnapshot(entries: [
        _entry('over-kwd', 'KWD', 12000, 10000, health: BudgetHealth.over),
        _entry('safe-kwd', 'KWD', 2345, 20000, endDays: mixedEnds ? 3 : 8),
        _entry('over-sar', 'SAR', 999999, 100, health: BudgetHealth.over),
      ]),
      historyEntries: const [],
      catalog: _catalog,
      accounts: const [],
      goals: [
        _goal('KWD one', 'KWD', 12345, 50000),
        _goal('KWD two', 'KWD', 1000, 20000),
        _goal('SAR excluded', 'SAR', 999999, 9999999),
        _goal('KWD inactive', 'KWD', 0, 0, status: 'closed'),
      ]);
  await _pump(
      tester,
      ProviderScope(overrides: [
        planningCutoverCoordinatorProvider.overrideWithValue(
            const FixedPlanningCutoverCoordinator(
                PlanningCutoverState.canonical)),
        baseCurrencyProvider.overrideWith((ref) async => 'KWD'),
        budgetsViewProvider.overrideWith((ref) async => view),
        budgetsPageTabProvider.overrideWith((ref) => goals ? 2 : 0),
      ], child: const BudgetsScreen()),
      language: language,
      dark: dark);
  return AppL10n.of(tester.element(find.byType(BudgetsScreen)));
}

void main() {
  for (final language in ['ar', 'en']) {
    for (final dark in [false, true]) {
      testWidgets(
          'today has precise availability, a58px ring and intact rows in $language dark=$dark',
          (tester) async {
        TransactionEntity? tapped;
        final available = Money(9007199254740993, 'KWD');
        await _pump(
            tester,
            _daily(
                limit: Money(24690, 'KWD'),
                available: available,
                onTap: (tx) => tapped = tx),
            language: language,
            dark: dark);
        final ring = tester.widget<RingProgress>(
            find.byKey(const ValueKey('today-budget-ring')));
        expect(ring.size, 58);
        expect(tester.getSize(find.byKey(const ValueKey('today-budget-ring'))),
            const Size(58, 58));
        expect(ring.value, .5);
        expect(find.text(formatMoney(available)), findsOneWidget,
            reason:
                'the full available amount must appear once, without duplicated metric');
        expect(find.text('8.765'), findsOneWidget);
        expect(find.text('Debit merchant'), findsOneWidget);
        expect(find.text('Income must stay excluded'), findsNothing);
        await tester.tap(find.text('Debit merchant'));
        expect(tapped?.id, 'Debit merchant');
        expect(tester.takeException(), isNull);
      });

      testWidgets(
          'goals hero shows saved while target KPI remains distinct in $language dark=$dark',
          (tester) async {
        final l10n =
            await _budgets(tester, goals: true, language: language, dark: dark);
        final header = tester
            .widgetList<CalmPageHeader>(find.byType(CalmPageHeader))
            .singleWhere((header) => header.photo == QirshPhoto.goals);
        expect(header.subtitle, l10n.bdgStatTotalSaved);
        expect(header.amount, '13.345');
        expect(
            header.metrics!
                .singleWhere(
                    (metric) => metric.label == l10n.bdgStatTargetSavings)
                .value,
            '70.000');
        expect(
            header.metrics!
                .singleWhere(
                    (metric) => metric.label == l10n.bdgStatActiveGoals)
                .value,
            '2');
        expect(
            find.textContaining('13.345', findRichText: true), findsOneWidget);
        expect(find.text('70.000'), findsOneWidget);
        expect(find.text('999.999'), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final limit in <Money?>[
    null,
    Money.zero('KWD'),
    Money(-1, 'KWD'),
    Money(1000, 'SAR')
  ]) {
    testWidgets(
        'undefined or incompatible allowance has no invented progress: $limit',
        (tester) async {
      await _pump(tester, _daily(limit: limit));
      expect(find.byKey(const ValueKey('today-budget-ring')), findsNothing);
      expect(find.text('—'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('privacy hides both availability and ring progress',
      (tester) async {
    await _pump(
        tester,
        _daily(
            limit: Money(24690, 'KWD'),
            available: Money(99999, 'KWD'),
            privacy: true));
    expect(
        tester
            .widget<RingProgress>(
                find.byKey(const ValueKey('today-budget-ring')))
            .value,
        isNull);
    expect(find.text('99.999'), findsNothing);
    expect(find.text('12.345'), findsNothing);
    expect(find.text('8.765'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final mixedEnds in [false, true]) {
    testWidgets(
        'budget count and exact photo footnote scope currencies; mixedEnds=$mixedEnds',
        (tester) async {
      final l10n = await _budgets(tester, goals: false, mixedEnds: mixedEnds);
      final header = tester
          .widgetList<CalmPageHeader>(find.byType(CalmPageHeader))
          .singleWhere((header) => header.photo == QirshPhoto.wallet);
      expect(header.amount, '30.000');
      expect(
          header.metrics!
              .singleWhere((metric) => metric.label == l10n.bdgOver)
              .value,
          '1');
      expect(header.amountFootnote, contains('${l10n.bdgActualSpend} 14.345'));
      expect(header.amountFootnote, contains('${l10n.bdgRemaining} 15.655'));
      if (mixedEnds) {
        expect(header.amountFootnote, isNot(contains(l10n.goalDaysLeft(8))));
      } else {
        expect(header.amountFootnote, contains(l10n.goalDaysLeft(8)));
      }
      expect(find.text(header.amountFootnote!), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  for (final language in ['ar', 'en']) {
    for (final currency in ['KWD', 'JPY']) {
      testWidgets(
          'standalone goals preserve exact $currency values and navigation in $language',
          (tester) async {
        final saved =
            Money(currency == 'KWD' ? 9007199254740993 : 123, currency);
        final target =
            Money(currency == 'KWD' ? 9007199254753338 : 456, currency);
        final goal = _goal(
            'Precision goal', currency, saved.minorUnits, target.minorUnits);
        var detailReads = 0;
        await _pump(tester, const GoalsScreen(),
            overrides: [
              planningCutoverCoordinatorProvider.overrideWithValue(
                  const FixedPlanningCutoverCoordinator(
                      PlanningCutoverState.canonical)),
              baseCurrencyProvider.overrideWith((ref) async => currency),
              goalsListProvider.overrideWith((ref) async =>
                  [goal, _goal('SAR excluded goal', 'SAR', 987654, 999999)]),
              bannerEligibilityProvider(AdPlacement.goals)
                  .overrideWith((ref) async => false),
              goalDetailsProvider(goal.id).overrideWith((ref) async {
                detailReads++;
                return GoalDetailsEntity(
                    goal: goal,
                    contributions: const [],
                    progress: .5,
                    remainingAmount: target - saved,
                    recommendedDailyAmount: Money.zero(currency),
                    recommendedWeeklyAmount: Money.zero(currency),
                    daysRemaining: null);
              }),
            ],
            language: language,
            dark: language == 'ar');
        final l10n = AppL10n.of(tester.element(find.byType(GoalsScreen)));
        final header =
            tester.widget<CalmPageHeader>(find.byType(CalmPageHeader));
        expect(header.amount, formatMoney(saved));
        expect(
            header.metrics!
                .singleWhere((m) => m.label == l10n.goalTargetLabel)
                .value,
            formatMoney(target));
        expect(
            header.metrics!
                .singleWhere((m) => m.label == l10n.bdgStatActiveGoals)
                .value,
            '1');
        expect(find.textContaining(formatMoney(saved), findRichText: true),
            findsNWidgets(2),
            reason:
                'saved appears once in the header and once in its goal card');
        final cardAmount = find.text(
            '${formatMoney(saved)} / ${formatMoney(target)}',
            findRichText: true);
        expect(cardAmount, findsOneWidget);
        expect(tester.widget<RichText>(cardAmount).textDirection,
            TextDirection.ltr);
        expect(find.textContaining(formatMoney(target), findRichText: true),
            findsNWidgets(2));
        final remaining = find.textContaining(formatMoney(target - saved));
        expect(remaining, findsOneWidget);
        expect(find.text('SAR excluded goal'), findsNothing);
        expect(find.textContaining('987.654'), findsNothing);
        expect(tester.takeException(), isNull);
        final cardName = find.text(goal.name);
        await tester.ensureVisible(cardName);
        await tester.tap(cardName);
        await tester.pumpAndSettle();
        expect(find.byType(BottomSheet), findsOneWidget);
        expect(detailReads, 1);
        expect(find.text(goal.name), findsNWidgets(2));
        expect(tester.takeException(), isNull);
      });
    }
  }
}
