import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/widgets/qirsh_visuals.dart';
import 'package:money_companion/core/utils/app_lucide_icons.dart';
import 'package:money_companion/domain/entities/plan_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/common/app_missing_record_state.dart';
import 'package:money_companion/features/common/category_catalog.dart';
import 'package:money_companion/features/goals/goal_details_screen.dart';
import 'package:money_companion/features/goals/goals_providers.dart';
import 'package:money_companion/features/plans/plans_providers.dart';
import 'package:money_companion/features/plans/plans_screen.dart';
import 'package:money_companion/features/transactions/transaction_details_screen.dart';
import 'package:money_companion/features/transactions/transactions_providers.dart';
import 'package:money_companion/l10n/app_localizations.dart';

void main() {
  for (final language in ['ar', 'en']) {
    for (final surface in ['transactionPage', 'transactionSheet', 'goalPage', 'goalSheet', 'planSheet']) {
      testWidgets('missing $surface preserves exact copy and navigation at375 2x text $language',
          (tester) async {
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
        final plan = PlanEntity(id: 'missing-plan', name: 'Synthetic plan',
          budgetAmountMoney: Money.parse('1000', 'EGP'), currency: 'EGP',
          startDate: DateTime(2026, 10, 1), endDate: DateTime(2027, 1, 1),
          accountIds: const [], cardLast4s: const [], status: PlanStatus.active,
          createdAt: DateTime(2026, 10, 1));
        await tester.pumpWidget(ProviderScope(overrides: [
          transactionByIdProvider('missing-tx').overrideWith((ref) async => null),
          categoryCatalogProvider.overrideWith((ref) async => CategoryCatalog(const [])),
          goalDetailsProvider('missing-goal').overrideWith((ref) async => null),
          plansWithSpentProvider.overrideWith((ref) async => [PlanProgress(plan, Money.zero('EGP'))]),
          planProgressProvider('missing-plan').overrideWith((ref) async => null),
          planTransactionsProvider('missing-plan').overrideWith((ref) async => const []),
          accountsProvider.overrideWith((ref) async => const []),
        ], child: MaterialApp(theme: language == 'ar' ? AppTheme.dark : AppTheme.light,
          locale: Locale(language), supportedLocales: AppL10n.supportedLocales,
          localizationsDelegates: AppL10n.localizationsDelegates,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!),
          home: Builder(builder: (context) => Scaffold(body: TextButton(
            onPressed: () {
              switch (surface) {
                case 'transactionPage':
                  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) =>
                    const TransactionDetailsScreen(transactionId: 'missing-tx')));
                case 'transactionSheet':
                  TransactionDetailsScreen.showSheet(context, 'missing-tx');
                case 'goalPage':
                  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) =>
                    const GoalDetailsScreen(goalId: 'missing-goal')));
                case 'goalSheet':
                  GoalDetailsScreen.showSheet(context, 'missing-goal');
                case 'planSheet':
                  PlansScreen.open(context);
              }
            }, child: const Text('Launch missing record')))))));
        await tester.tap(find.text('Launch missing record'));
        await tester.pumpAndSettle();
        if (surface == 'planSheet') {
          await tester.tap(find.text('Synthetic plan'));
          await tester.pumpAndSettle();
        }
        final missing = find.byType(AppMissingRecordState);
        expect(missing, findsOneWidget);
        final context = tester.element(missing);
        final l10n = AppL10n.of(context);
        final expected = surface.startsWith('transaction') ? l10n.txdNotFound
            : surface.startsWith('goal') ? l10n.gdNotFound : l10n.plNotFound;
        final message = find.descendant(of: missing, matching: find.text(expected));
        await tester.ensureVisible(message);
        await tester.pumpAndSettle();
        expect(message.hitTestable(), findsOneWidget);
        final text = tester.widget<Text>(message);
        expect(text.maxLines, isNull);
        expect(text.overflow, isNull);
        final art = tester.widget<QirshIllustration>(find.descendant(of: missing,
            matching: find.byType(QirshIllustration)));
        expect(art.name, surface.startsWith('transaction') ? 'emptyTx'
            : surface.startsWith('goal') ? 'savings' : 'plans');
        expect(art.width, 160);
        expect(art.height, 120);
        expect(find.descendant(of: missing, matching: find.byWidgetPredicate(
            (widget) => widget is ButtonStyleButton || widget is IconButton)), findsNothing);
        expect(tester.getRect(message).left, greaterThanOrEqualTo(0));
        expect(tester.getRect(message).right, lessThanOrEqualTo(375));
        final close = surface.endsWith('Page') ? find.byType(BackButton)
            : find.widgetWithIcon(IconButton, AppLucideIcons.x);
        expect(close.hitTestable(), findsOneWidget);
        await tester.tap(close);
        await tester.pumpAndSettle();
        expect(missing, findsNothing);
        expect(surface == 'planSheet' ? find.byType(PlansScreen)
            : find.text('Launch missing record'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
