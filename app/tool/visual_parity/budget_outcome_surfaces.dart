// Offline QA only. Actual public budget forms with held/error writes.
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:money_companion/core/backend/supabase_config.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/i18n/locale_provider.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_budget_repository.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/budget_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/usecases/save_budget_usecase.dart';
import 'package:money_companion/features/budgets/allocate_income_sheet.dart';
import 'package:money_companion/features/budgets/budget_form_screen.dart';

const visualParityBudgetOutcomeKeys = <String>[
  'budgetFormSaving',
  'budgetFormError',
  'allocateIncomeSaving',
  'allocateIncomeError',
];
final _events = <String, int>{};
Map<String, int> visualParityBudgetOutcomeEvents() => Map.unmodifiable(_events);
void _event(String key) => _events.update(key, (n) => n + 1, ifAbsent: () => 1);

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'budget-outcome-owned-memory';
  @override
  Future<String?> readStoredKey() async => 'budget-outcome-owned-memory';
}

class _BudgetOutcome extends DriftBudgetRepository {
  _BudgetOutcome(super.database, this.key);
  final String key;
  @override
  Future<BudgetEntity> save(BudgetEntity budget) {
    if (budget.currency != 'KWD' ||
        budget.accountId != 'qa-budget-account' ||
        budget.amountMoney.minorUnits !=
            (key.startsWith('budgetForm') ? 12345 : 150000) ||
        budget.period != BudgetPeriod.monthly) {
      throw StateError('budget_outcome_unexpected_input');
    }
    if (key.startsWith('budgetForm') && budget.id != 'qa-budget-edit') {
      throw StateError('budget_outcome_unexpected_identity');
    }
    _event(key);
    return key.endsWith('Saving')
        ? Completer<BudgetEntity>().future
        : Future<BudgetEntity>.error(
            StateError('private_budget_outcome_failure'));
  }

  @override
  Future<void> delete(String id) {
    _event('budgetOutcomeForbiddenDelete');
    throw StateError('budget_outcome_delete_forbidden');
  }
}

Future<bool> openVisualParityBudgetOutcome(
    BuildContext context, WidgetRef ref, String key) async {
  if (!visualParityBudgetOutcomeKeys.contains(key)) return false;
  if (!kDebugMode || SupabaseConfig.isConfigured) {
    throw StateError('budget_outcome_requires_offline_debug');
  }
  final parent = ref.read(appDatabaseProvider);
  final databases = await parent.customSelect('PRAGMA database_list').get();
  if (!databases.any((r) =>
      r.read<String>('name') == 'main' && r.read<String>('file').isEmpty)) {
    throw StateError('budget_outcome_requires_memory_parent');
  }
  if (!context.mounted) return false;
  final locale = Localizations.localeOf(context);
  final database = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _Keys(),
      initialLanguage: 'en');
  ProviderContainer? container;
  try {
    // Setup uses actual canonical repositories before interception is installed.
    final setup = ProviderContainer(
        overrides: [appDatabaseProvider.overrideWithValue(database)]);
    try {
      final now = DateTime.utc(2026, 11, 1);
      final settings = setup.read(userSettingsRepositoryProvider);
      await settings.saveSettings((await settings.getSettings())
          .copyWith(currency: 'KWD', country: 'KW'));
      await setup.read(accountRepositoryProvider).create(AccountEntity(
          id: 'qa-budget-account',
          name: 'QA KWD account',
          currency: 'KWD',
          type: AccountType.bank,
          isDefault: true,
          sortOrder: 0,
          createdAt: now,
          updatedAt: now,
          initialBalanceMoney: Money.zero('KWD'),
          currentBalanceMoney: Money.zero('KWD')));
      if (key.startsWith('budgetForm')) {
        final categories =
            await setup.read(categoryRepositoryProvider).getAll();
        final groceries = categories.singleWhere((c) => c.key == 'groceries');
        await setup.read(budgetRepositoryProvider).save(BudgetEntity(
            id: 'qa-budget-edit',
            categoryId: groceries.id,
            currency: 'KWD',
            amountMoney: Money(12345, 'KWD'),
            lastNotifiedSpentMoney: Money.zero('KWD'),
            period: BudgetPeriod.monthly,
            startDate: now,
            isActive: true,
            lastNotifiedPeriodStart: now,
            accountId: 'qa-budget-account'));
      }
    } finally {
      setup.dispose();
    }
    final repository = _BudgetOutcome(database, key);
    container = ProviderContainer(overrides: [
      appDatabaseProvider.overrideWithValue(database),
      localeProvider.overrideWithValue(locale),
      budgetRepositoryProvider.overrideWithValue(repository),
      saveBudgetUseCaseProvider
          .overrideWithValue(SaveBudgetUseCase(repository)),
    ]);
    if (!context.mounted) {
      container.dispose();
      await database.close();
      return false;
    }
    final owned = container;
    _event('${key}Opened');
    unawaited(Navigator.of(context).push<void>(MaterialPageRoute<void>(
        builder: (_) =>
            _BudgetHost(container: owned, database: database, keyName: key))));
    return true;
  } catch (_) {
    container?.dispose();
    await database.close();
    rethrow;
  }
}

class _BudgetHost extends StatefulWidget {
  const _BudgetHost(
      {required this.container, required this.database, required this.keyName});
  final ProviderContainer container;
  final AppDatabase database;
  final String keyName;
  @override
  State<_BudgetHost> createState() => _BudgetHostState();
}

class _BudgetHostState extends State<_BudgetHost> {
  @override
  void dispose() {
    widget.container.dispose();
    unawaited(
        widget.database.close().then((_) => _event('${widget.keyName}Closed')));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => UncontrolledProviderScope(
        container: widget.container,
        child: Navigator(
            onGenerateRoute: (_) => MaterialPageRoute<void>(
                builder: (_) => _BudgetLauncher(keyName: widget.keyName))),
      );
}

class _BudgetLauncher extends StatefulWidget {
  const _BudgetLauncher({required this.keyName});
  final String keyName;
  @override
  State<_BudgetLauncher> createState() => _BudgetLauncherState();
}

class _BudgetLauncherState extends State<_BudgetLauncher> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      if (widget.keyName.startsWith('budgetForm')) {
        await BudgetFormScreen.showSheet(context, budgetId: 'qa-budget-edit');
      } else {
        await AllocateIncomeSheet.show(context);
      }
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold();
}
