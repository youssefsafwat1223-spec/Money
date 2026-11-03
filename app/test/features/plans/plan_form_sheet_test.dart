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
  Future<String> readOrCreateKey() async => 'memory';
  @override
  Future<String?> readStoredKey() async => 'memory';
}

void main() {
  late AppDatabase db;
  late DriftPlanRepository repository;
  setUp(() async {
    db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _MemoryKeys());
    repository = DriftPlanRepository(db);
  });
  tearDown(() async => db.close());

  for (final language in ['ar', 'en']) {
    for (final dateShape in ['canonical', 'non-midnight', 'DST-midnight-end']) {
    testWidgets('editing a plan preserves its stored icon and exact untouched $dateShape fields in $language', (tester) async {
      tester.view.physicalSize = const Size(375, 667);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final existing = PlanEntity(
        id: 'synthetic-icon-plan', name: 'Family trip',
        budgetAmountMoney: Money.parse('1234.567', 'KWD'), currency: 'KWD',
        startDate: switch (dateShape) {
          'non-midnight' => DateTime.utc(2026, 10, 20, 9, 42, 13, 456),
          'DST-midnight-end' => DateTime.utc(2026, 10, 22, 22),
          _ => DateTime(2026, 10, 1),
        },
        endDate: switch (dateShape) {
          'non-midnight' => DateTime.utc(2026, 11, 12, 16, 17, 23, 123),
          'DST-midnight-end' => DateTime.utc(2026, 11, 12, 22),
          _ => DateTime(2026, 11, 1, 23, 59, 59),
        },
        accountIds: const ['synthetic-account'],
        cardLast4s: const ['4471'], status: PlanStatus.closed,
        createdAt: DateTime.utc(2026, 9, 15), icon: 'plane',
      );
      await repository.save(existing);
      late BuildContext launcherContext;
      await tester.pumpWidget(ProviderScope(overrides: [
        appDatabaseProvider.overrideWithValue(db),
        planRepositoryProvider.overrideWithValue(repository),
      ], child: MaterialApp(
        theme: language == 'ar' ? AppTheme.dark : AppTheme.light,
        locale: Locale(language),
        supportedLocales: AppL10n.supportedLocales,
        localizationsDelegates: AppL10n.localizationsDelegates,
        home: Builder(builder: (context) {
          launcherContext = context;
          return const Scaffold(body: Text('Synthetic plan launcher'));
        }),
      )));
      await tester.pumpAndSettle();

      for (final editedName in <String?>[null, 'Updated family trip']) {
        final stored = (await repository.getById(existing.id))!;
        // Use the public production form; actual Save goes through Drift.
        // The returned modal future completes only after Save dismisses it.
        PlanFormSheet.show(launcherContext, existing: stored);
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(find.byType(TextField).at(1))
            .controller!.text, '1234.567');
        if (editedName != null) {
          await tester.enterText(find.byType(TextField).first, editedName);
          tester.testTextInput.hide();
          await tester.pumpAndSettle();
        }
        final l10n = AppL10n.of(tester.element(find.byType(PlanFormSheet)));
        await tester.tap(find.widgetWithText(FilledButton, l10n.pfSavePlan));
        await tester.pumpAndSettle();
        final saved = (await repository.getById(existing.id))!;
        expect(saved.icon, 'plane');
        expect(saved.name, editedName ?? existing.name);
        expect(saved.budgetAmountMoney, existing.budgetAmountMoney);
        expect(saved.currency, existing.currency);
        expect(saved.accountIds, existing.accountIds);
        expect(saved.cardLast4s, existing.cardLast4s);
        expect(saved.startDate, existing.startDate.toUtc());
        expect(saved.endDate, existing.endDate.toUtc());
        expect(saved.status, existing.status);
        expect(saved.createdAt, existing.createdAt);
        expect(find.byType(PlanFormSheet), findsNothing);
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
    }
  }
}
