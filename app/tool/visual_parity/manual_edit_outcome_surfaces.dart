// Public manual-edit QA in owned memory. Never imported by lib/.
import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:money_companion/core/backend/supabase_config.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/i18n/locale_provider.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_bill_repository.dart';
import 'package:money_companion/data/repositories/drift_category_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/usecases/confirm_transaction_usecase.dart';
import 'package:money_companion/features/transactions/manual_transaction_sheet.dart';

const visualParityManualEditOutcomeKeys = [
  'manualEditSaveBusy',
  'manualEditSaveError',
  'manualEditDeleteBusy',
  'manualEditDeleteError',
  'manualEditConfirmBusy',
  'manualEditConfirmError',
  'manualAwaitingPricing',
];
final _events = <String, int>{};
final _receipts = <String, Map<String, Object?>>{};
Map<String, int> visualParityManualEditOutcomeEvents() =>
    Map.unmodifiable(_events);
Map<String, Map<String, Object?>> visualParityManualEditOutcomeReceipts() =>
    Map.unmodifiable(_receipts);
void _record(String key) =>
    _events.update(key, (n) => n + 1, ifAbsent: () => 1);

Future<String> _sqlSnapshot(AppDatabase db) async {
  final tables = await db
      .customSelect(
          "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
      .get();
  final snapshot = <String, Object>{};
  for (final table in tables) {
    final name = table.read<String>('name');
    snapshot[name] =
        (await db.customSelect('SELECT * FROM "$name" ORDER BY rowid').get())
            .map((row) => row.data)
            .toList();
  }
  return jsonEncode(snapshot);
}

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'owned-manual-edit-memory';
  @override
  Future<String?> readStoredKey() async => 'owned-manual-edit-memory';
}

// Only actual read methods are inherited. Every write entry reachable from the
// public edit form is refused before super can mutate or return a result.
class _RefusingTransactions extends DriftTransactionRepository {
  _RefusingTransactions(super.db, this.key);
  final String key;
  Completer<void>? _held;
  Future<void>? _active;
  bool _closing = false;

  String? get operation => key.contains('Save')
      ? 'save'
      : key.contains('Delete')
          ? 'delete'
          : key.contains('Confirm')
              ? 'confirm'
              : null;

  Future<Never> _refuse(
      String requested, Map<String, Object?> arguments) async {
    _record('${key}Attempt');
    if (_closing || requested != operation) {
      _record('${key}ForbiddenWrite');
      throw StateError('manual_edit_unexpected_write');
    }
    _receipts[key] = Map.unmodifiable({
      ..._receipts[key]!,
      'operation': requested,
      'arguments': Map.unmodifiable(arguments),
      'phase': key.endsWith('Busy') ? 'held' : 'refused'
    });
    if (key.endsWith('Busy')) {
      if (_held != null) {
        _record('${key}ForbiddenDoubleAdmission');
        throw StateError('manual_edit_double_admission');
      }
      _held = Completer<void>();
      _active = _held!.future;
      _record('${key}Held');
      try {
        await _active;
      } finally {
        _record('${key}Settled');
      }
    }
    _record('${key}Refused');
    throw StateError('manual_edit_controlled_failure');
  }

  Future<void> cancelAndSettle() async {
    _closing = true;
    if (_held != null && !_held!.isCompleted) {
      _held!.completeError(StateError('manual_edit_fixture_closed'));
      _record('${key}Cancelled');
    }
    try {
      await _active;
    } catch (_) {/* The public handler also owns this error. */}
  }

  @override
  Future<TransactionEntity> updateTransaction(
          {required String transactionId,
          required Money amount,
          required String currency,
          required TransactionTypeEntity type,
          required DateTime occurredAt,
          required String? rawMerchant,
          required String? categoryId,
          required String? note,
          String? accountId}) =>
      _refuse('save', {
        'transactionId': transactionId,
        'amountMinor': amount.minorUnits,
        'currency': currency,
        'accountId': accountId,
        'type': type.name,
        'occurredAt': occurredAt.toUtc().toIso8601String(),
        'categoryId': categoryId,
      });
  @override
  Future<void> deleteTransaction(String transactionId) =>
      _refuse('delete', {'transactionId': transactionId});
  @override
  Future<TransactionEntity> confirm(String transactionId) =>
      _refuse('confirm', {'transactionId': transactionId});
}

class _NoBillCleanup extends DriftBillRepository {
  _NoBillCleanup(super.db, this.key);
  final String key;
  @override
  Future<List<String>> deletePaymentForTransaction(String transactionId) async {
    _record('${key}ForbiddenBillCleanup');
    throw StateError('manual_edit_bill_cleanup_must_not_run');
  }
}

Future<bool> openVisualParityManualEditOutcome(
    BuildContext context, WidgetRef ref, String key) async {
  if (!visualParityManualEditOutcomeKeys.contains(key)) return false;
  if (!kDebugMode || SupabaseConfig.isConfigured) {
    throw StateError('manual_edit_requires_offline_debug');
  }
  if (!context.mounted) return false;
  final locale = Localizations.localeOf(context);
  final parent = ref.read(appDatabaseProvider);
  final databases = await parent.customSelect('PRAGMA database_list').get();
  if (!databases.any((row) =>
      row.read<String>('name') == 'main' && row.read<String>('file').isEmpty)) {
    throw StateError('manual_edit_requires_memory_database');
  }
  final db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _Keys(),
      initialLanguage: 'en');
  ProviderContainer? container;
  _RefusingTransactions? refusing;
  String? baseline;
  Future<void>? closing;
  Future<void> close() => closing ??= (() async {
        // Delete is inside a real outer Drift transaction. Reject the held call
        // first, then an outside query must wait for its rollback. Never snapshot
        // or close a database while an uncompleted transaction owns its executor.
        try {
          await refusing?.cancelAndSettle();
          await db.customSelect('SELECT 1').get();
          if (baseline != null) {
            final unchanged = await _sqlSnapshot(db) == baseline;
            _receipts[key] = Map.unmodifiable({
              ..._receipts[key]!,
              'childAllSqlUnchanged': unchanged,
              'phase': 'closed'
            });
            if (!unchanged) throw StateError('manual_edit_child_sql_changed');
            _record('${key}AllSqlUnchanged');
          }
        } finally {
          container?.dispose();
          await db.close();
          _record('${key}Closed');
        }
      })();
  try {
    final accounts = DriftAccountRepository(db);
    final at = DateTime.utc(2026, 11, 1);
    final account = await accounts.create(AccountEntity(
        id: 'qa-manual-edit-egp',
        name: 'QA isolated EGP account',
        currency: 'EGP',
        type: AccountType.bank,
        isDefault: true,
        sortOrder: 0,
        initialBalanceMoney: Money.zero('EGP'),
        currentBalanceMoney: Money.zero('EGP'),
        createdAt: at,
        updatedAt: at));
    final awaiting = key == 'manualAwaitingPricing';
    final actual = await DriftTransactionRepository(db).saveTransaction(
        transaction: TransactionEntity(
            id: 'qa-manual-edit-row',
            accountId: account.id,
            amountMoney: awaiting ? Money.zero('EGP') : Money(2468, 'EGP'),
            currency: 'EGP',
            foreignMoney: awaiting ? Money(12345, 'KWD') : null,
            foreignCurrency: awaiting ? 'KWD' : null,
            type: TransactionTypeEntity.payment,
            source: TransactionSourceEntity.bank,
            occurredAt: at,
            rawMessage: 'Synthetic manual QA',
            rawMerchant: 'QA purchase',
            note: 'Synthetic draft',
            parseConfidence: .6,
            status: TransactionStatus.pending,
            createdAt: at,
            updatedAt: at),
        categoryKey: 'groceries');
    final transactions = refusing = _RefusingTransactions(db, key);
    container = ProviderContainer(overrides: [
      appDatabaseProvider.overrideWithValue(db),
      localeProvider.overrideWithValue(locale),
      accountRepositoryProvider.overrideWithValue(accounts),
      categoryRepositoryProvider.overrideWithValue(DriftCategoryRepository(db)),
      transactionRepositoryProvider.overrideWithValue(transactions),
      billRepositoryProvider.overrideWithValue(_NoBillCleanup(db, key)),
      confirmTransactionUseCaseProvider
          .overrideWithValue(ConfirmTransactionUseCase(transactions)),
    ]);
    baseline = await _sqlSnapshot(db);
    _receipts[key] = Map.unmodifiable({
      'syntheticOnly': true,
      'transactionId': actual.id,
      'amountMinor': actual.amountMoney.minorUnits,
      'currency': actual.currency,
      'status': actual.status.name,
      'foreignAmountMinor': actual.foreignMoney?.minorUnits,
      'foreignCurrency': actual.foreignCurrency,
      'pricingState': actual.pricingState.name,
      'phase': 'ready'
    });
    _record('${key}Opened');
    if (!context.mounted) {
      await close();
      return false;
    }
    final owned = container;
    unawaited(Navigator.of(context)
        .push<void>(MaterialPageRoute<void>(
            builder: (_) => _Lifetime(
                close: close,
                child: UncontrolledProviderScope(
                    container: owned,
                    child: Navigator(
                        onGenerateRoute: (_) => MaterialPageRoute<void>(
                            builder: (_) => _EditHost(
                                transaction: actual,
                                closeOuter: () {
                                  if (context.mounted) {
                                    Navigator.of(context).pop();
                                  }
                                })))))))
        .whenComplete(close));
    return true;
  } catch (_) {
    await close();
    rethrow;
  }
}

class _Lifetime extends StatefulWidget {
  const _Lifetime({required this.close, required this.child});
  final Future<void> Function() close;
  final Widget child;
  @override
  State<_Lifetime> createState() => _LifetimeState();
}

class _LifetimeState extends State<_Lifetime> {
  @override
  void dispose() {
    unawaited(widget.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _EditHost extends StatefulWidget {
  const _EditHost({required this.transaction, required this.closeOuter});
  final TransactionEntity transaction;
  final VoidCallback closeOuter;
  @override
  State<_EditHost> createState() => _EditHostState();
}

class _EditHostState extends State<_EditHost> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await ManualTransactionSheet.show(context,
          transaction: widget.transaction);
      if (mounted) widget.closeOuter();
    });
  }

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('Isolated manual edit QA')));
}
