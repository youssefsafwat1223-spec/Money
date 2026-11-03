import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/widgets/glass_dropdown_field.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_budget_repository.dart';
import 'package:money_companion/data/repositories/drift_category_repository.dart';
import 'package:money_companion/data/repositories/drift_goal_repository.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/budget_entity.dart';
import 'package:money_companion/domain/entities/category_entity.dart';
import 'package:money_companion/domain/entities/goal_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/usecases/save_budget_usecase.dart';
import 'package:money_companion/features/budgets/allocate_income_sheet.dart';
import 'package:money_companion/features/common/category_catalog.dart';
import 'package:money_companion/features/goals/goals_providers.dart';
import 'package:money_companion/l10n/app_localizations.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory';
  @override
  Future<String?> readStoredKey() async => 'memory';
}

class _RefusingBudgets extends DriftBudgetRepository {
  _RefusingBudgets(super.db);
  @override
  Future<BudgetEntity> save(BudgetEntity budget) async =>
      throw StateError('synthetic_budget_save_failure');
}

void main() {
  late AppDatabase db;
  late DriftAccountRepository accounts;
  late DriftBudgetRepository budgets;
  late DriftGoalRepository goals;
  late List<CategoryEntity> categories;
  late GoalEntity goal;
  setUp(() async {
    db = await AppDatabase.open(executor: NativeDatabase.memory(), keyStore: _Keys());
    accounts = DriftAccountRepository(db);
    budgets = DriftBudgetRepository(db);
    goals = DriftGoalRepository(db);
    final now = DateTime.utc(2026, 1, 1);
    categories = (await DriftCategoryRepository(db).getAll())
        .where((category) => ['groceries', 'bills'].contains(category.key)).toList();
    expect(categories, hasLength(2));
    await accounts.create(AccountEntity(id: 'synthetic-account', name: 'Synthetic account',
      currency: 'EGP', type: AccountType.bank, isDefault: true, sortOrder: 0,
      createdAt: now, updatedAt: now, initialBalanceMoney: Money.zero('EGP'),
      currentBalanceMoney: Money.zero('EGP')));
    goal = GoalEntity(id: 'synthetic-goal', name: 'Synthetic KWD goal', accountId: 'synthetic-account',
      currency: 'KWD', targetMoney: Money(50000, 'KWD'), savedMoney: Money.zero('KWD'),
      lastNotifiedSavedMoney: Money.zero('KWD'), vaultSkin: 'default_vault',
      status: 'active', createdAt: now);
    await goals.save(goal);
  });
  tearDown(() async => db.close());

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (!tester.binding.hasScheduledFrame) return;
    }
  }

  Future<AppL10n> open(WidgetTester tester, {bool refuseSave = false}) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(overrides: [
      appDatabaseProvider.overrideWithValue(db),
      accountRepositoryProvider.overrideWithValue(accounts),
      budgetRepositoryProvider.overrideWithValue(budgets),
      goalRepositoryProvider.overrideWithValue(goals),
      saveBudgetUseCaseProvider.overrideWithValue(SaveBudgetUseCase(
          refuseSave ? _RefusingBudgets(db) : budgets)),
      activeAccountIdProvider.overrideWith((ref) => 'synthetic-account'),
      baseCurrencyProvider.overrideWith((ref) async => 'EGP'),
      goalsListProvider.overrideWith((ref) async => [goal]),
      categoryCatalogProvider.overrideWith((ref) async => CategoryCatalog(categories,
          languageCode: 'en')),
    ], child: MaterialApp(theme: AppTheme.light, locale: const Locale('en'),
      supportedLocales: AppL10n.supportedLocales, localizationsDelegates: AppL10n.localizationsDelegates,
      home: Scaffold(body: Builder(builder: (context) => TextButton(
        onPressed: () => AllocateIncomeSheet.show(context), child: const Text('Open allocation'),
      ))),
    )));
    await tester.tap(find.text('Open allocation'));
    await settle(tester);
    return AppL10n.of(tester.element(find.byType(AllocateIncomeSheet)));
  }

  Future<void> enter(WidgetTester tester, int field, String value) async {
    await tester.ensureVisible(find.byType(TextField).at(field));
    await tester.enterText(find.byType(TextField).at(field), value);
    tester.testTextInput.hide();
    await settle(tester);
  }

  Future<Object?> saveAndCaptureFailure(WidgetTester tester, AppL10n l10n) async {
    final save = find.widgetWithText(FilledButton, l10n.aiSaveSplit);
    await tester.ensureVisible(save);
    final callback = tester.widget<FilledButton>(save).onPressed;
    expect(callback, isNotNull);
    Object? failure;
    // Await the actual async production Save callback so an old uncaught error
    // cannot prevent inspecting partial Drift writes in this regression.
    await tester.runAsync(() async {
      try {
        final pending = (callback as dynamic)();
        if (pending is Future) await pending;
      } catch (error) {
        failure = error;
      }
    });
    await settle(tester);
    return failure;
  }

  Future<List<Map<String, Object?>>> budgetRows() async =>
      (await db.customSelect('SELECT * FROM budgets ORDER BY id').get()).map((r) => r.data).toList();

  testWidgets('localized income enables the existing suggestion action', (tester) async {
    final l10n = await open(tester);
    await enter(tester, 0, '١٠٠٠٫٠٠');
    final suggest = find.widgetWithText(TextButton, l10n.aiSuggestSplit);
    expect(tester.widget<TextButton>(suggest).onPressed, isNotNull);
    await tester.tap(suggest);
    await settle(tester);
    expect(tester.widget<TextField>(find.byType(TextField).at(1)).controller!.text, '150');
    expect(tester.widget<TextField>(find.byType(TextField).at(2)).controller!.text, '120');
    expect(tester.widget<TextField>(find.byType(TextField).at(3)).controller!.text, '200');
    expect(await budgetRows(), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mixed ASCII and Arabic envelopes both reach real canonical persistence', (tester) async {
    final l10n = await open(tester);
    await enter(tester, 1, '10.00');
    await enter(tester, 2, '١٢٫٣٤');
    final failure = await saveAndCaptureFailure(tester, l10n);
    final result = await budgets.getAll();
    debugPrint('ALLOCATION_REPRO mixed saved=${result.map((b) => '${b.categoryId}:${b.amountMoney}').toList()} failure=${failure.runtimeType}');
    expect(result.map((b) => (b.categoryId, b.amountMoney)),
        unorderedEquals([
          (categories.singleWhere((c) => c.key == 'groceries').id, Money(1000, 'EGP')),
          (categories.singleWhere((c) => c.key == 'bills').id, Money(1234, 'EGP')),
        ]));
    expect(failure, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('invalid later envelope cannot leave an earlier canonical budget written', (tester) async {
    final l10n = await open(tester);
    final before = await budgetRows();
    await enter(tester, 1, '10.00');
    await enter(tester, 2, '12.345');
    final failure = await saveAndCaptureFailure(tester, l10n);
    final after = await budgetRows();
    debugPrint('ALLOCATION_REPRO laterEnvelope before=$before after=$after failure=${failure.runtimeType}');
    expect(after, before, reason: 'all input must validate before the first envelope is written');
    expect(failure, isNull);
    expect(find.byType(AllocateIncomeSheet), findsOneWidget);
    expect(find.text(l10n.gfEnterValidAmount), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, l10n.aiSaveSplit)).onPressed, isNotNull);
    await tester.pump(const Duration(seconds: 4));
    await settle(tester);
  });

  testWidgets('invalid goal savings cannot write envelopes or remove existing roll-up first', (tester) async {
    final now = DateTime.utc(2026, 1, 1);
    await budgets.save(BudgetEntity(id: 'synthetic-rollup', categoryId: BudgetEntity.allExpensesCategoryId,
      currency: 'EGP', amountMoney: Money(9000, 'EGP'), lastNotifiedSpentMoney: Money.zero('EGP'),
      period: BudgetPeriod.monthly, startDate: now, isActive: true,
      lastNotifiedPeriodStart: now, accountId: 'synthetic-account'));
    final l10n = await open(tester);
    final before = await budgetRows();
    await enter(tester, 1, '10.00');
    await enter(tester, 3, '12.3456');
    await tester.tap(find.byType(GlassDropdownField<String>));
    await settle(tester);
    await tester.tap(find.text(goal.name).last);
    await settle(tester);
    final failure = await saveAndCaptureFailure(tester, l10n);
    final after = await budgetRows();
    debugPrint('ALLOCATION_REPRO savings before=$before after=$after failure=${failure.runtimeType}');
    expect(after, before, reason: 'goal-currency input must validate before any envelope write or roll-up deletion');
    expect((await goals.getById(goal.id))!.autoSaveMoney, isNull);
    expect(failure, isNull);
    expect(find.byType(AllocateIncomeSheet), findsOneWidget);
    expect(find.text(l10n.gfEnterValidAmount), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    await settle(tester);
  });

  testWidgets('positive Arabic KWD savings uses selected goal currency before EGP envelopes', (tester) async {
    final l10n = await open(tester);
    await enter(tester, 1, '10.00');
    await enter(tester, 2, '١٢٫٣٤');
    await enter(tester, 3, '١٢٫٣٤٥');
    await tester.tap(find.byType(GlassDropdownField<String>));
    await settle(tester);
    await tester.tap(find.text(goal.name).last);
    await settle(tester);
    final failure = await saveAndCaptureFailure(tester, l10n);
    final saved = await budgets.getAll();
    expect(saved, hasLength(2));
    expect(saved.map((budget) => budget.amountMoney),
        unorderedEquals([Money(1000, 'EGP'), Money(1234, 'EGP')]));
    final savedGoal = (await goals.getById(goal.id))!;
    expect(savedGoal.autoSaveMoney, Money(12345, 'KWD'));
    expect(savedGoal.autoSavePeriod, 'monthly');
    expect(savedGoal.targetMoney, goal.targetMoney);
    expect(savedGoal.savedMoney, goal.savedMoney);
    expect(savedGoal.currency, goal.currency);
    expect(savedGoal.accountId, goal.accountId);
    expect(failure, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed repository save reports error and releases busy without an atomicity claim', (tester) async {
    final l10n = await open(tester, refuseSave: true);
    await enter(tester, 1, '10.00');
    final failure = await saveAndCaptureFailure(tester, l10n);
    expect(await budgetRows(), isEmpty);
    expect(failure, isNull);
    expect(find.text(l10n.bfSaveFailed), findsOneWidget);
    expect(find.byType(AllocateIncomeSheet), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, l10n.aiSaveSplit)).onPressed, isNotNull);
    expect(tester.widget<TextField>(find.byType(TextField).at(1)).controller!.text, '10.00');
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 4));
    await settle(tester);
  });

  for (final skipped in ['', '0', '-2']) {
    testWidgets('optional nonpositive envelope $skipped keeps existing skip semantics', (tester) async {
      final l10n = await open(tester);
      await enter(tester, 1, '10.00');
      await enter(tester, 2, skipped);
      final failure = await saveAndCaptureFailure(tester, l10n);
      final saved = await budgets.getAll();
      expect(saved, hasLength(1));
      expect(saved.single.categoryId, categories.singleWhere((c) => c.key == 'groceries').id);
      expect(saved.single.amountMoney, Money(1000, 'EGP'));
      expect(failure, isNull);
      expect(tester.takeException(), isNull);
    });
  }
}
