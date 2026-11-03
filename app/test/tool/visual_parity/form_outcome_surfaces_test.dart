import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_bill_repository.dart';
import 'package:money_companion/data/repositories/drift_card_repository.dart';
import 'package:money_companion/data/repositories/drift_goal_repository.dart';
import 'package:money_companion/data/repositories/drift_plan_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/bill_entity.dart';
import 'package:money_companion/domain/entities/card_entity.dart';
import 'package:money_companion/domain/entities/goal_entity.dart';
import 'package:money_companion/domain/entities/plan_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/engine/parser/card_network.dart';
import 'package:money_companion/features/common/app_button.dart';
import 'package:money_companion/l10n/app_localizations.dart';

import '../../../tool/visual_parity/form_outcome_surfaces.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'form-outcome-memory-only';
  @override
  Future<String?> readStoredKey() async => 'form-outcome-memory-only';
}

class _Open extends ConsumerWidget {
  const _Open(this.surface);
  final String surface;
  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(body: TextButton(
    onPressed: () async => openVisualParityFormOutcome(context, ref, surface),
    child: const Text('Open form fixture'),
  ));
}

Future<Map<String, Object>> _snapshot(AppDatabase db) async {
  final tables = await db.customSelect(
      "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name").get();
  return {
    for (final row in tables)
      row.read<String>('name'): (await db.customSelect(
          'SELECT * FROM "${row.read<String>('name')}" ORDER BY rowid').get())
          .map((value) => value.data).toList(),
  };
}

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 80)));
  await tester.pumpAndSettle();
}

Future<void> _reveal(WidgetTester tester, Finder target) async {
  for (var attempt = 0; attempt < 18; attempt++) {
    if (target.hitTestable().evaluate().isNotEmpty) return;
    final scrollables = find.byType(Scrollable).evaluate().where((element) {
      final state = (element as StatefulElement).state as ScrollableState;
      if (state.position.maxScrollExtent <= 0 ||
          state.widget.axisDirection == AxisDirection.left ||
          state.widget.axisDirection == AxisDirection.right) {
        return false;
      }
      final render = element.renderObject as RenderBox;
      final top = render.localToGlobal(Offset.zero).dy;
      return render.hasSize && top < 667 && top + render.size.height > 80;
    }).toList();
    if (scrollables.isEmpty) break;
    final scroll = find.byElementPredicate((element) => identical(element, scrollables.first));
    await tester.drag(scroll, const Offset(0, -220));
    await tester.pumpAndSettle();
  }
  expect(target.hitTestable(), findsOneWidget,
      reason: 'Actual save control must be reachable through visible public vertical scrolling.');
}

void main() {
  late AppDatabase db;
  setUp(() async {
    db = await AppDatabase.open(executor: NativeDatabase.memory(),
      keyStore: _Keys(), initialLanguage: 'en');
  });
  tearDown(() async => db.close());

  for (final family in ['account', 'card', 'bill', 'goal', 'plan']) {
    for (final error in [false, true]) {
      for (final language in ['ar', 'en']) {
        for (final dark in [false, true]) {
          testWidgets('$family ${error ? 'error' : 'saving'} $language dark$dark public edit never writes', (tester) async {
            tester.view.physicalSize = const Size(375, 667);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            final accounts = DriftAccountRepository(db);
            final cards = DriftCardRepository(db);
            final bills = DriftBillRepository(db);
            final goals = DriftGoalRepository(db);
            final plans = DriftPlanRepository(db);
            final transactions = DriftTransactionRepository(db);
            final now = DateTime.now().toUtc();
            await accounts.create(AccountEntity(id: 'p-acc-1', name: 'Actual fixture account',
              currency: 'EGP', type: AccountType.bank, isDefault: true, sortOrder: 0,
              initialBalanceMoney: Money(125000, 'EGP'), currentBalanceMoney: Money(125000, 'EGP'),
              createdAt: now, updatedAt: now));
            await cards.create(CardEntity(id: 'qa-deck-gold', accountId: 'p-acc-1',
              last4: '8821', network: CardNetwork.visa, source: CardSource.manual,
              nickname: 'Actual fixture card', createdAt: now, updatedAt: now));
            await bills.save(BillEntity(id: 'p-bill-0', name: 'Actual fixture subscription',
              amountMoney: Money(25000, 'EGP'), currency: 'EGP', type: BillType.subscription,
              frequency: BillFrequency.monthly, nextDueDate: now.add(const Duration(days: 3)),
              reminderOn: false, isConfirmed: true, createdAt: now, accountId: 'p-acc-1'));
            await goals.save(GoalEntity(id: 'p-goal-0', name: 'Actual fixture goal',
              accountId: 'p-acc-1', targetMoney: Money(100000, 'EGP'), savedMoney: Money(10000, 'EGP'),
              lastNotifiedSavedMoney: Money.zero('EGP'), currency: 'EGP', vaultSkin: 'default_vault',
              status: 'active', createdAt: now, deadline: now.add(const Duration(days: 30))));
            await plans.save(PlanEntity(id: 'p-plan-active', name: 'Actual fixture plan',
              budgetAmountMoney: Money(100000, 'EGP'), currency: 'EGP',
              startDate: now.subtract(const Duration(days: 2)), endDate: now.add(const Duration(days: 10)),
              accountIds: const ['p-acc-1'], cardLast4s: const [], status: PlanStatus.active, createdAt: now));
            final before = await _snapshot(db);
            final key = '${family}Form${error ? 'Error' : 'Saving'}';
            final prior = visualParityFormOutcomeEvents()[key] ?? 0;
            final container = ProviderContainer(overrides: [
              appDatabaseProvider.overrideWithValue(db),
              accountRepositoryProvider.overrideWithValue(accounts),
              cardRepositoryProvider.overrideWithValue(cards),
              billRepositoryProvider.overrideWithValue(bills),
              goalRepositoryProvider.overrideWithValue(goals),
              planRepositoryProvider.overrideWithValue(plans),
              transactionRepositoryProvider.overrideWithValue(transactions),
              userSettingsRepositoryProvider.overrideWithValue(DriftUserSettingsRepository(db)),
            ]);
            addTearDown(container.dispose);
            await tester.pumpWidget(UncontrolledProviderScope(container: container,
              child: MaterialApp(theme: dark ? AppTheme.dark : AppTheme.light,
                locale: Locale(language), supportedLocales: AppL10n.supportedLocales,
                localizationsDelegates: AppL10n.localizationsDelegates,
                home: _Open(key))));
            await tester.tap(find.text('Open form fixture'));
            await _settle(tester);
            final l10n = AppL10n.of(tester.element(find.byType(TextField).first));
            final Finder save = switch (family) {
              'account' => find.byKey(const ValueKey('account-save-button')),
              'bill' => find.byKey(const ValueKey('bill-save-button')),
              'goal' => find.widgetWithText(AppPrimaryButton, l10n.gfSaveEdit),
              'plan' => find.widgetWithText(FilledButton, l10n.pfSavePlan),
              _ => find.widgetWithText(FilledButton, l10n.txdSave),
            };
            await _reveal(tester, save);
            final savePosition = tester.getCenter(save);
            await tester.tap(save);
            if (error) {
              await _settle(tester);
              final message = family == 'account' ? l10n.afSaveFailed
                  : family == 'card' ? l10n.cfSaveFailed : l10n.bfSaveFailed;
              expect(find.text(message), findsOneWidget);
              expect(find.textContaining('private_synthetic'), findsNothing);
              expect(visualParityFormOutcomeEvents()[key], prior + 1);
              await tester.tap(save);
              await _settle(tester);
              expect(visualParityFormOutcomeEvents()[key], prior + 2,
                reason: 'Existing form permits retry after caught failure.');
              await tester.pump(const Duration(seconds: 7));
              await tester.pumpAndSettle();
            } else {
              await tester.pump(const Duration(milliseconds: 160));
              expect(find.byType(CircularProgressIndicator), findsWidgets);
              expect(visualParityFormOutcomeEvents()[key], prior + 1);
              // The public save control is still laid out; its callback refuses
              // a second admission while the original repository write waits.
              await tester.tapAt(savePosition);
              await tester.pump(const Duration(milliseconds: 80));
              expect(visualParityFormOutcomeEvents()[key], prior + 1);
            }
            expect(await _snapshot(db), before,
              reason: 'Every actual SQLite user-table row remains unchanged.');
            expect(identical(container.read(accountRepositoryProvider), accounts), isTrue);
            expect(identical(container.read(cardRepositoryProvider), cards), isTrue);
            expect(identical(container.read(billRepositoryProvider), bills), isTrue);
            expect(identical(container.read(goalRepositoryProvider), goals), isTrue);
            expect(identical(container.read(planRepositoryProvider), plans), isTrue);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
            await tester.pump();
          });
        }
      }
    }
  }

  for (final family in ['account', 'card', 'bill', 'goal', 'plan']) {
    testWidgets('$family requires actual existing row before showing form', (tester) async {
      final before = await _snapshot(db);
      Object? rejection;
      await tester.pumpWidget(ProviderScope(overrides: [
        appDatabaseProvider.overrideWithValue(db),
      ], child: MaterialApp(home: Consumer(builder: (context, ref, _) =>
        Scaffold(body: TextButton(onPressed: () async {
          try { await openVisualParityFormOutcome(context, ref, '${family}FormError'); }
          catch (error) { rejection = error; }
        }, child: const Text('guard')))))));
      await tester.tap(find.text('guard'));
      await _settle(tester);
      expect(rejection, isA<StateError>());
      expect(rejection.toString(), contains('form_outcome_requires_existing_fixture_row'));
      expect(await _snapshot(db), before);
      expect(tester.takeException(), isNull);
    });
  }
}
