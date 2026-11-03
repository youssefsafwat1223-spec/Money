// Guarded offline QA only. Child fixtures own a separate memory database.
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:money_companion/core/backend/supabase_config.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/account_deletion_service.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/accounts/account_form_sheet.dart';

const visualParityAccountGuardKeys = <String>[
  'accountCurrencyLinked',
  'accountCurrencyUsageLoading',
  'accountCurrencyUsageError',
  'accountCannotDeleteLast',
  'accountSoleDefault',
];
final _events = <String, int>{};
Map<String, int> visualParityAccountGuardEvents() => Map.unmodifiable(_events);
void _event(String key) => _events.update(key, (n) => n + 1, ifAbsent: () => 1);

class _MemoryKeys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'account-guard-qa-memory';
  @override
  Future<String?> readStoredKey() async => 'account-guard-qa-memory';
}

/// Only delegates the actual SQL usage read; any deletion operation fails closed.
class _ReadOnlyUsage implements FinancialAccountDeletionService {
  _ReadOnlyUsage(this.actual);
  final FinancialAccountDeletionService actual;
  @override
  Future<bool> hasTransactions(String accountId) =>
      actual.hasTransactions(accountId);
  @override
  dynamic noSuchMethod(Invocation invocation) {
    _event('accountGuardForbiddenDeletionOperation');
    throw StateError('account_guard_deletion_operation_forbidden');
  }
}

Future<bool> openVisualParityAccountGuard(
    BuildContext context, WidgetRef ref, String key) async {
  if (!visualParityAccountGuardKeys.contains(key)) return false;
  if (!kDebugMode || SupabaseConfig.isConfigured) {
    throw StateError('account_guard_requires_offline_debug');
  }
  final parents = await ref
      .read(appDatabaseProvider)
      .customSelect('PRAGMA database_list')
      .get();
  if (!parents.any((r) =>
      r.read<String>('name') == 'main' && r.read<String>('file').isEmpty)) {
    throw StateError('account_guard_requires_memory_parent');
  }
  final database = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeys(),
      initialLanguage: 'en');
  ProviderContainer? container;
  try {
    container = ProviderContainer(overrides: [
      appDatabaseProvider.overrideWithValue(database),
      financialAccountDeletionServiceProvider.overrideWith((ref) =>
          _ReadOnlyUsage(FinancialAccountDeletionService(
              db: database,
              accounts: ref.watch(accountRepositoryProvider),
              cards: ref.watch(cardRepositoryProvider),
              budgets: ref.watch(budgetRepositoryProvider),
              goals: ref.watch(goalRepositoryProvider),
              bills: ref.watch(billRepositoryProvider)))),
      if (key == 'accountCurrencyUsageLoading' ||
          key == 'accountCurrencyUsageError')
        accountHasTransactionsProvider('qa-account-guard').overrideWith((ref) {
          _event('${key}Read');
          return key.endsWith('Loading')
              ? Completer<bool>().future
              : Future<bool>.error(StateError('private_account_usage_failure'));
        }),
    ]);
    final accounts = container.read(accountRepositoryProvider);
    if ((await accounts.getAll()).isNotEmpty) {
      throw StateError('account_guard_child_not_empty');
    }
    final now = DateTime.utc(2026, 11, 1);
    AccountEntity account(String id) => AccountEntity(
        id: id,
        name: 'QA KWD account',
        currency: 'KWD',
        type: AccountType.bank,
        isDefault: false,
        sortOrder: 0,
        createdAt: now,
        updatedAt: now,
        initialBalanceMoney: Money.zero('KWD'),
        currentBalanceMoney: Money.zero('KWD'));
    AccountEntity target;
    if (key == 'accountCannotDeleteLast') {
      // Real stale form entity: another account disappears after this nondefault
      // row was read. The live repository promotes it, without changing the old
      // entity held by an already-open form. No fabricated default flag.
      await accounts.create(account('qa-account-guard-old-default'));
      target = await accounts.create(account('qa-account-guard'));
      if (target.isDefault) {
        throw StateError('account_guard_target_not_nondefault');
      }
      await accounts.delete('qa-account-guard-old-default');
      _event('accountGuardStaleSetupCompleted');
    } else {
      target = await accounts.create(account('qa-account-guard'));
    }
    if (key == 'accountCurrencyLinked') {
      await container.read(transactionRepositoryProvider).saveTransaction(
          transaction: TransactionEntity(
              id: 'qa-account-guard-transaction',
              amountMoney: Money(12345, 'KWD'),
              currency: 'KWD',
              accountId: target.id,
              type: TransactionTypeEntity.payment,
              source: TransactionSourceEntity.imported,
              occurredAt: now,
              rawMessage: 'Synthetic account usage fixture',
              rawMerchant: 'QA account guard',
              parseConfidence: 1,
              status: TransactionStatus.confirmed,
              createdAt: now,
              updatedAt: now),
          categoryKey: null);
    }
    if (!context.mounted) {
      container.dispose();
      await database.close();
      return false;
    }
    _event('${key}Opened');
    final child = container;
    unawaited(Navigator.of(context).push<void>(MaterialPageRoute<void>(
      builder: (_) => _AccountGuardHost(
          container: child, database: database, account: target, keyName: key),
    )));
    return true;
  } catch (_) {
    container?.dispose();
    await database.close();
    rethrow;
  }
}

class _AccountGuardHost extends ConsumerStatefulWidget {
  const _AccountGuardHost(
      {required this.container,
      required this.database,
      required this.account,
      required this.keyName});
  final ProviderContainer container;
  final AppDatabase database;
  final AccountEntity account;
  final String keyName;
  @override
  ConsumerState<_AccountGuardHost> createState() => _AccountGuardHostState();
}

class _AccountGuardHostState extends ConsumerState<_AccountGuardHost> {
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
                builder: (_) =>
                    _AccountGuardLauncher(account: widget.account))),
      );
}

class _AccountGuardLauncher extends ConsumerStatefulWidget {
  const _AccountGuardLauncher({required this.account});
  final AccountEntity account;
  @override
  ConsumerState<_AccountGuardLauncher> createState() =>
      _AccountGuardLauncherState();
}

class _AccountGuardLauncherState extends ConsumerState<_AccountGuardLauncher> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await showAccountForm(context, ref, account: widget.account);
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold();
}
