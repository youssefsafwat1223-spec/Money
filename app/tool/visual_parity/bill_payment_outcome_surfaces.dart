// Offline QA only. Actual BillDetails payment UI, before its first mutation.
import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:money_companion/core/backend/supabase_config.dart';
import 'package:money_companion/core/di/account_access_mode.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/i18n/locale_provider.dart';
import 'package:money_companion/core/session/account_scope.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_bill_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/bill_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/usecases/add_transaction_usecase.dart';
import 'package:money_companion/features/subscriptions/bill_details_sheet.dart';

const visualParityBillPaymentOutcomeKeys = [
  'billPaymentInvalid',
  'billPaymentBusy',
  'billPaymentError',
];
final visualParityBillPaymentOutcomeOverlay = ValueNotifier<Widget?>(null);
final _events = <String, int>{};
Map<String, int> visualParityBillPaymentOutcomeEvents() =>
    Map.unmodifiable(_events);
void _event(String key) => _events.update(key, (n) => n + 1, ifAbsent: () => 1);
_BillFixture? _active;
BuildContext? get visualParityBillPaymentOutcomeInspectionContext =>
    _active?.navigator.currentContext;
const _accountId = 'qa-bill-payment-account';

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'bill-payment-owned-memory';
  @override
  Future<String?> readStoredKey() async => 'bill-payment-owned-memory';
}

Future<String> _snapshot(AppDatabase db) async {
  final tables = await db
      .customSelect(
          "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
      .get();
  return jsonEncode({
    for (final table in tables)
      table.read<String>('name'): (await db
              .customSelect(
                  'SELECT * FROM "${table.read<String>('name')}" ORDER BY rowid')
              .get())
          .map((row) => row.data)
          .toList()
  });
}

class _PaymentTransactions extends DriftTransactionRepository {
  _PaymentTransactions(super.db, this.key);
  final String key;
  Completer<TransactionEntity>? _held;
  Future<TransactionEntity>? _activeWrite;
  @override
  Future<TransactionEntity> saveTransaction(
      {required TransactionEntity transaction,
      required String? categoryKey,
      String? resolvedCategoryId}) {
    if (key == 'billPaymentInvalid' ||
        transaction.amountMoney != Money(12345, 'KWD') ||
        transaction.currency != 'KWD' ||
        transaction.accountId != _accountId ||
        transaction.type != TransactionTypeEntity.payment ||
        transaction.status != TransactionStatus.confirmed ||
        transaction.rawMerchant != 'QA KWD subscription' ||
        categoryKey != 'subscriptions' ||
        resolvedCategoryId != null) {
      _event('billPaymentForbiddenWrite');
      throw StateError('bill_payment_unexpected_input');
    }
    _event(key);
    if (key == 'billPaymentBusy') {
      if (_held != null) {
        _event('billPaymentForbiddenWrite');
        throw StateError('bill_payment_double_admission');
      }
      _held = Completer<TransactionEntity>();
      _activeWrite = _held!.future.whenComplete(() => _event('${key}Settled'));
      return _activeWrite!;
    }
    return Future<TransactionEntity>.error(
        StateError('private_bill_payment_failure'));
  }

  Future<void> cancelAndSettle() async {
    if (_held case final pending? when !pending.isCompleted) {
      _event('${key}Cancelled');
      pending.completeError(StateError('bill_payment_fixture_closed'));
    }
    try {
      await _activeWrite;
    } catch (_) {/* Actual public handler owns error. */}
  }
}

class _NoPaymentWrites extends DriftBillRepository {
  _NoPaymentWrites(super.db);
  @override
  Future<BillPaymentEntity> recordPayment(BillPaymentEntity payment) {
    _event('billPaymentForbiddenLink');
    throw StateError('bill_payment_link_must_not_run');
  }
}

Future<bool> openVisualParityBillPaymentOutcome(
    BuildContext context, WidgetRef ref, String key) async {
  if (!visualParityBillPaymentOutcomeKeys.contains(key)) return false;
  if (!kDebugMode || SupabaseConfig.isConfigured) {
    throw StateError('bill_payment_requires_offline_debug');
  }
  if (ref.read(accountAccessModeProvider) != AccountAccessMode.writable) {
    throw StateError('bill_payment_requires_writable_memory_parent');
  }
  final databases = await ref
      .read(appDatabaseProvider)
      .customSelect('PRAGMA database_list')
      .get();
  if (!databases.any((r) =>
      r.read<String>('name') == 'main' && r.read<String>('file').isEmpty)) {
    throw StateError('bill_payment_requires_memory_parent');
  }
  if (!context.mounted) return false;
  if (_active != null) throw StateError('bill_payment_already_open');
  final locale = Localizations.localeOf(context);
  final db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _Keys(),
      initialLanguage: 'en');
  ProviderContainer? child;
  try {
    final at = DateTime.utc(2026, 11, 1);
    final accounts = DriftAccountRepository(db);
    await accounts.create(AccountEntity(
        id: _accountId,
        name: 'QA KWD payment account',
        currency: 'KWD',
        type: AccountType.bank,
        isDefault: true,
        sortOrder: 0,
        createdAt: at,
        updatedAt: at,
        initialBalanceMoney: Money(100000, 'KWD'),
        currentBalanceMoney: Money(100000, 'KWD')));
    final setup = DriftBillRepository(db);
    await setup.save(BillEntity(
        id: 'qa-bill-payment-bill',
        name: 'QA KWD subscription',
        amountMoney: Money(12345, 'KWD'),
        currency: 'KWD',
        type: BillType.subscription,
        frequency: BillFrequency.monthly,
        nextDueDate: DateTime.utc(2026, 12, 1),
        reminderOn: false,
        isConfirmed: true,
        createdAt: at,
        accountId: _accountId));
    final bill = (await setup.getById('qa-bill-payment-bill'))!;
    final transactions = _PaymentTransactions(db, key);
    child = ProviderContainer(overrides: [
      appDatabaseProvider.overrideWithValue(db),
      localeProvider.overrideWithValue(locale),
      accountRepositoryProvider.overrideWithValue(accounts),
      transactionRepositoryProvider.overrideWithValue(transactions),
      billRepositoryProvider.overrideWithValue(_NoPaymentWrites(db)),
      saveManualTransactionUseCaseProvider.overrideWithValue(
          SaveManualTransactionUseCase(
              transactionRepository: transactions,
              accountRepository: accounts)),
    ]);
    final baseline = await _snapshot(db);
    if (!context.mounted) {
      child.dispose();
      await db.close();
      return false;
    }
    final fixture = _BillFixture(db, child, transactions, bill, baseline, key);
    _active = fixture;
    _event('${key}Opened');
    visualParityBillPaymentOutcomeOverlay.value = _BillHost(fixture);
    return true;
  } catch (_) {
    child?.dispose();
    await db.close();
    rethrow;
  }
}

Future<void> closeVisualParityBillPaymentOutcome() {
  final fixture = _active;
  if (fixture == null) return Future<void>.value();
  // Busy dialog disables Cancel/Pop. QA teardown removes only its owned sibling.
  visualParityBillPaymentOutcomeOverlay.value = null;
  if (!fixture.mounted) unawaited(fixture.disposeOnce());
  return fixture.closed.future;
}

class _BillFixture {
  _BillFixture(this.db, this.container, this.transactions, this.bill,
      this.baseline, this.key);
  final AppDatabase db;
  final ProviderContainer container;
  final _PaymentTransactions transactions;
  final BillEntity bill;
  final String baseline;
  final String key;
  final navigator = GlobalKey<NavigatorState>();
  final closed = Completer<void>();
  bool mounted = false;
  bool disposing = false;
  Future<void> disposeOnce() async {
    if (disposing) return;
    disposing = true;
    await Future<void>.delayed(Duration.zero);
    _event('${key}UnmountedBeforeCancel');
    try {
      await transactions.cancelAndSettle();
      await db.customSelect('SELECT 1').get();
      if (await _snapshot(db) != baseline) {
        throw StateError('bill_payment_child_sql_changed');
      }
      _event('${key}AllSqlUnchanged');
    } finally {
      container.dispose();
      await db.close();
      if (identical(_active, this)) {
        _active = null;
        visualParityBillPaymentOutcomeOverlay.value = null;
      }
      _event('${key}Closed');
      closed.complete();
    }
  }
}

class _BillHost extends StatefulWidget {
  const _BillHost(this.fixture);
  final _BillFixture fixture;
  @override
  State<_BillHost> createState() => _BillHostState();
}

class _BillHostState extends State<_BillHost> {
  @override
  void initState() {
    super.initState();
    widget.fixture.mounted = true;
  }

  @override
  void dispose() {
    widget.fixture.mounted = false;
    unawaited(widget.fixture.disposeOnce());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => UncontrolledProviderScope(
      container: widget.fixture.container,
      child: HeroControllerScope.none(
          child: Navigator(
              key: widget.fixture.navigator,
              onGenerateRoute: (_) => MaterialPageRoute<void>(
                  builder: (_) => _BillLaunch(widget.fixture)))));
}

class _BillLaunch extends StatefulWidget {
  const _BillLaunch(this.fixture);
  final _BillFixture fixture;
  @override
  State<_BillLaunch> createState() => _BillLaunchState();
}

class _BillLaunchState extends State<_BillLaunch> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await BillDetailsSheet.show(context, widget.fixture.bill);
      if (mounted) unawaited(closeVisualParityBillPaymentOutcome());
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold();
}
