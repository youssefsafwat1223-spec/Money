import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/domain/entities/budget_entity.dart';
import 'package:money_companion/domain/entities/category_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/repositories/transaction_repository.dart';
import 'package:money_companion/features/budgets/budget_form_screen.dart';
import 'package:money_companion/features/common/category_catalog.dart';
import 'package:money_companion/l10n/app_localizations.dart';

/// THE CONTROL ITSELF — reachable, readable while you drag it, and announced.
///
/// A percentage the user cannot read until they let go is a percentage they
/// cannot aim at, and a slider with no semantics is invisible to VoiceOver.
/// Both are checked here against the real form, not a reconstruction.
/// The form suggests an amount from the last 30 days of spending, which needs a
/// database. Only the two totals matter here, and both are money; everything
/// else on the interface is unreachable from this screen.
class _StubTransactions implements TransactionRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      Future<Money>.value(Money(0, 'SAR'));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  /// Bounded, not `pumpAndSettle`. This form carries a glass/shimmer treatment
  /// that never reaches quiescence, so settling waits forever — the same
  /// reason every capture harness in this repo pumps on a budget.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (!tester.binding.hasScheduledFrame) return;
    }
  }

  Future<void> pumpForm(WidgetTester tester, {required String language}) async {
    tester.view.physicalSize = const Size(400, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          categoryCatalogProvider.overrideWith((ref) async => CategoryCatalog(
                const [
                  CategoryEntity(
                    id: 'cat-food',
                    key: 'food',
                    nameAr: 'طعام',
                    icon: 'utensils',
                    color: '#FF0000',
                    isIncome: false,
                    sort: 1,
                  ),
                ],
                languageCode: language,
              )),
          accountsProvider.overrideWith((ref) async => const []),
          transactionRepositoryProvider.overrideWithValue(_StubTransactions()),
          baseCurrencyProvider.overrideWith((ref) async => 'SAR'),
        ],
        child: MaterialApp(
          locale: Locale(language),
          supportedLocales: AppL10n.supportedLocales,
          localizationsDelegates: const [
            ...AppL10n.localizationsDelegates,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          theme: AppTheme.light,
          home: const Scaffold(body: BudgetFormScreen()),
        ),
      ),
    );
    await settle(tester);
  }

  testWidgets('the budget form offers the alert threshold, at 80 by default',
      (tester) async {
    await pumpForm(tester, language: 'en');
    final l10n = await AppL10n.delegate.load(const Locale('en'));

    expect(find.text(l10n.bfBudgetAlert), findsOneWidget,
        reason: 'no way to choose when this budget warns');
    expect(find.byType(Slider), findsOneWidget);

    final slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.value, BudgetEntity.defaultAlertThresholdPercent.toDouble());
    expect(slider.min, 10);
    expect(slider.max, 100);
    // 5% steps: 30, 50 and 80 are all reachable, which is the owner's ask.
    expect(slider.divisions, 18);
    expect(find.text(l10n.bfBudgetAlertValue('80')), findsOneWidget,
        reason: 'the chosen value must be on screen, not only in the thumb');
  });

  testWidgets('dragging updates the visible percentage as it moves',
      (tester) async {
    await pumpForm(tester, language: 'en');
    final l10n = await AppL10n.delegate.load(const Locale('en'));

    // Drag toward the start of the track. The exact landing value depends on
    // track geometry, so this asserts the reading CHANGED and stayed on the
    // 5% grid rather than pinning a pixel-derived number.
    await tester.drag(find.byType(Slider), const Offset(-120, 0));
    await settle(tester);

    final slider = tester.widget<Slider>(find.byType(Slider));
    final value = slider.value.round();
    expect(value, lessThan(80), reason: 'the drag did not move the value');
    expect(value % BudgetEntity.alertThresholdStepPercent, 0,
        reason: 'landed off the 5% grid');
    expect(find.text(l10n.bfBudgetAlertValue('$value')), findsOneWidget,
        reason: 'the label did not follow the thumb');
  });

  testWidgets('it is announced with its purpose and value, not "slider, 80"',
      (tester) async {
    await pumpForm(tester, language: 'en');
    final l10n = await AppL10n.delegate.load(const Locale('en'));
    final slider = tester.widget<Slider>(find.byType(Slider));

    expect(slider.semanticFormatterCallback, isNotNull,
        reason: 'VoiceOver would read a bare number with no purpose');
    final announced = slider.semanticFormatterCallback!(80);
    expect(announced, contains(l10n.bfBudgetAlert));
    expect(announced, contains('80'));
  });

  testWidgets('Arabic renders the control RTL, in the app\'s own digits',
      (tester) async {
    await pumpForm(tester, language: 'ar');
    final l10n = await AppL10n.delegate.load(const Locale('ar'));

    expect(find.text(l10n.bfBudgetAlert), findsOneWidget);
    expect(find.byType(Slider), findsOneWidget);
    // Latin digits, deliberately. Every number in this app's Arabic UI is
    // Latin — amounts, dates, the dashboard's own «1,478.94» — because that is
    // what `NumberFormat` gives for `ar` and what the rest of the interface
    // already does. The Arabic NOTIFICATION copy is the one place that uses
    // Eastern digits («٨٠٪»), and it does so because the sentence around it
    // always has; see `budget_alert_planner`. Changing either to match the
    // other is a product decision about the app's Arabic voice, not something
    // this control should decide on its own.
    expect(find.text(l10n.bfBudgetAlertValue('80')), findsOneWidget);
    expect(
      Directionality.of(tester.element(find.byType(Slider))),
      TextDirection.rtl,
    );
  });
}
