import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_plan_repository.dart';
import 'package:money_companion/domain/entities/plan_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/plans/plan_form_sheet.dart';
import 'package:money_companion/l10n/app_localizations.dart';

class _MemoryKeys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'plan-validation-memory';
  @override
  Future<String?> readStoredKey() async => 'plan-validation-memory';
}

// Reads come from the actual seeded ledger. A submitted plan is recorded at
// the write boundary then fails, so no invalid or synthetic success is stored.
class _RecordPlanAttempt extends DriftPlanRepository {
  _RecordPlanAttempt(super.database);
  final attempts = <PlanEntity>[];
  @override
  Future<PlanEntity> save(PlanEntity plan) async {
    attempts.add(plan);
    throw StateError('synthetic_plan_write_failure');
  }
}

void main() {
  late AppDatabase db;
  late _RecordPlanAttempt repository;
  setUp(() async {
    db = await AppDatabase.open(executor: NativeDatabase.memory(),
        keyStore: _MemoryKeys());
    repository = _RecordPlanAttempt(db);
  });
  tearDown(() async => db.close());

  PlanEntity existing({bool legacyInvalidEnd = false}) {
    final now = DateTime.now();
    return PlanEntity(id: 'qa-plan-validation', name: 'QA family trip',
      budgetAmountMoney: Money.parse('1234.567', 'KWD'), currency: 'KWD',
      startDate: DateTime(now.year, now.month, 15, 9, 42, 13, 456),
      endDate: DateTime(now.year, now.month, legacyInvalidEnd ? 14 : 20, 22, 17, 23, 123),
      accountIds: const [], cardLast4s: const [], status: PlanStatus.active,
      createdAt: DateTime.utc(2026, 9, 15), icon: 'plane');
  }

  Future<List<Map<String, Object?>>> rawPlans() async =>
      (await db.customSelect('SELECT * FROM plans ORDER BY id').get())
          .map((row) => row.data).toList();

  Future<AppL10n> open(WidgetTester tester, String language, bool dark,
      PlanEntity plan) async {
    tester.view.physicalSize = const Size(375, 667);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await DriftPlanRepository(db).save(plan);
    await tester.pumpWidget(ProviderScope(overrides: [
      appDatabaseProvider.overrideWithValue(db),
      planRepositoryProvider.overrideWithValue(repository),
    ], child: MaterialApp(
      theme: dark ? AppTheme.dark : AppTheme.light,
      locale: Locale(language), supportedLocales: AppL10n.supportedLocales,
      localizationsDelegates: AppL10n.localizationsDelegates,
      home: Builder(builder: (context) => Scaffold(body: TextButton(
        onPressed: () => PlanFormSheet.show(context, existing: plan),
        child: const Text('open')))),
    )));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return AppL10n.of(tester.element(find.byType(PlanFormSheet)));
  }

  for (final language in ['ar', 'en']) {
    for (final dark in [false, true]) {
      for (final invalid in ['name', 'zero', 'negative']) {
        testWidgets('plan $invalid submit explains required value without persistence $language dark$dark', (tester) async {
          final plan = existing();
          final l10n = await open(tester, language, dark, plan);
          final before = await rawPlans();
          await tester.enterText(find.byType(TextField).at(invalid == 'name' ? 0 : 1),
              invalid == 'name' ? '   ' : invalid == 'zero' ? '0' : '-1');
          tester.testTextInput.hide();
          await tester.pumpAndSettle();
          await tester.tap(find.widgetWithText(FilledButton, l10n.pfSavePlan));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 500));
          expect(repository.attempts, isEmpty);
          expect(find.text(invalid == 'name' ? l10n.bfEnterName : l10n.bfAmountAboveZero), findsOneWidget);
          expect(find.byType(PlanFormSheet), findsOneWidget);
          expect(await rawPlans(), before);
          expect(tester.takeException(), isNull);
          await tester.pump(const Duration(seconds: 4));
        });
      }

      testWidgets('plan end picker ignores a day before start and retains valid instants $language dark$dark', (tester) async {
        final plan = existing();
        final l10n = await open(tester, language, dark, plan);
        final before = await rawPlans();
        await tester.tap(find.text(l10n.txnTo));
        await tester.pumpAndSettle();
        final calendar = find.byType(CalendarDatePicker);
        final labels = MaterialLocalizations.of(tester.element(calendar));
        await tester.tap(find.descendant(of: calendar, matching: find.text('14')));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, labels.okButtonLabel));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, l10n.pfSavePlan));
        await tester.pumpAndSettle();
        expect(repository.attempts, hasLength(1));
        final submitted = repository.attempts.single;
        expect(submitted.endDate.isBefore(submitted.startDate), isFalse);
        expect(submitted.startDate, plan.startDate);
        expect(submitted.endDate, plan.endDate);
        expect(submitted.budgetAmountMoney, plan.budgetAmountMoney);
        expect(submitted.icon, plan.icon);
        expect(await rawPlans(), before);
        expect(tester.takeException(), isNull);
        await tester.pump(const Duration(seconds: 4));
      });

      testWidgets('legacy invalid plan opens a bounded end picker without rewriting stored dates $language dark$dark', (tester) async {
        final plan = existing(legacyInvalidEnd: true);
        final l10n = await open(tester, language, dark, plan);
        final before = await rawPlans();
        await tester.tap(find.text(l10n.txnTo));
        await tester.pumpAndSettle();
        final calendar = tester.widget<CalendarDatePicker>(find.byType(CalendarDatePicker));
        expect(calendar.firstDate, DateUtils.dateOnly(plan.startDate));
        expect(calendar.initialDate, DateUtils.dateOnly(plan.startDate));
        final labels = MaterialLocalizations.of(tester.element(find.byType(CalendarDatePicker)));
        await tester.tap(find.widgetWithText(TextButton, labels.cancelButtonLabel));
        await tester.pumpAndSettle();
        expect(repository.attempts, isEmpty);
        expect(await rawPlans(), before);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
