// Offline QA only. One genuine owned-memory transaction commit, then link failure.
// Existing pre-first-write Bill helper is deliberately untouched.
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

const visualParityBillPartialLinkKeys = ['billPaymentPartialLinkError'];
final visualParityBillPartialLinkOverlay = ValueNotifier<Widget?>(null);
final _events = <String, int>{};
Map<String, int> visualParityBillPartialLinkEvents() =>
    Map.unmodifiable(_events);
void _event(String key) => _events.update(key, (n) => n + 1, ifAbsent: () => 1);
_PartialFixture? _active;
BuildContext? get visualParityBillPartialLinkInspectionContext =>
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

class _ActualTransactions extends DriftTransactionRepository {
  _ActualTransactions(super.db);
  int saves = 0;
  TransactionEntity? genuine;
  @override
  Future<TransactionEntity> saveTransaction(
      {required TransactionEntity transaction,
      required String? categoryKey,
      String? resolvedCategoryId}) async {
    if (saves != 0 ||
        transaction.amountMoney != Money(12345, 'KWD') ||
        transaction.currency != 'KWD' ||
        transaction.accountId != _accountId ||
        transaction.status != TransactionStatus.confirmed ||
        transaction.type != TransactionTypeEntity.payment ||
        transaction.rawMerchant != 'QA KWD subscription' ||
        categoryKey != 'subscriptions' ||
        resolvedCategoryId != null) {
      throw StateError('partial_unexpected_transaction');
    }
    saves++;
    _event('billPaymentPartialLinkErrorTransactionSave');
    genuine = await super.saveTransaction(
        transaction: transaction,
        categoryKey: categoryKey,
        resolvedCategoryId: resolvedCategoryId);
    return genuine!;
  }
}

class _PartialLinks extends DriftBillRepository {
  _PartialLinks(this.db, this.transactions) : super(db);
  final AppDatabase db;
  final _ActualTransactions transactions;
  final attempts = <BillPaymentEntity>[];
  String? postCommit;
  @override
  Future<BillPaymentEntity> recordPayment(BillPaymentEntity payment) async {
    final genuine = transactions.genuine;
    if (genuine == null ||
        payment.transactionId != genuine.id ||
        payment.billId != 'qa-bill-payment-bill' ||
        payment.amountMoney != Money(12345, 'KWD') ||
        payment.currency != 'KWD') {
      throw StateError('partial_link_without_genuine_transaction');
    }
    final snapshot = await _snapshot(db);
    if (postCommit != null && snapshot != postCommit) {
      throw StateError('partial_retry_changed_sql');
    }
    postCommit ??= snapshot;
    attempts.add(payment);
    _event('billPaymentPartialLinkErrorLinkAttempt');
    throw StateError('private_bill_partial_link_failure');
  }
}

Map<String, Object?> visualParityBillPartialLinkReceipt() {
  final f = _active;
  if (f == null) return Map.unmodifiable(_lastReceipt);
  return {
    'transactionSaves': f.transactions.saves,
    'transactionId': f.transactions.genuine?.id,
    'amountMinor': f.transactions.genuine?.amountMoney.minorUnits,
    'accountId': f.transactions.genuine?.accountId,
    'linkAttempts': f.links.attempts.length,
    'paymentAttemptIds': f.links.attempts.map((p) => p.id).toList(),
    'paymentTransactionIds':
        f.links.attempts.map((p) => p.transactionId).toList(),
    'paymentArguments': [
      for (final p in f.links.attempts)
        {
          'id': p.id,
          'billId': p.billId,
          'transactionId': p.transactionId,
          'amountMinor': p.amountMoney.minorUnits,
          'currency': p.currency,
          'periodStart': p.periodStart.toUtc().toIso8601String(),
          'periodEnd': p.periodEnd.toUtc().toIso8601String(),
          'paidAt': p.paidAt.toUtc().toIso8601String(),
          'installmentIndex': p.installmentIndex,
          'note': p.note
        }
    ],
  };
}

Map<String, Object?> _lastReceipt = {};

Future<bool> openVisualParityBillPartialLink(
    BuildContext context, WidgetRef ref, String key) async {
  if (!visualParityBillPartialLinkKeys.contains(key)) return false;
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
    final transactions = _ActualTransactions(db);
    final links = _PartialLinks(db, transactions);
    child = ProviderContainer(overrides: [
      appDatabaseProvider.overrideWithValue(db),
      localeProvider.overrideWithValue(locale),
      accountRepositoryProvider.overrideWithValue(accounts),
      transactionRepositoryProvider.overrideWithValue(transactions),
      billRepositoryProvider.overrideWithValue(links),
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
    final fixture =
        _PartialFixture(db, child, transactions, links, bill, baseline, key);
    _active = fixture;
    _event('${key}Opened');
    visualParityBillPartialLinkOverlay.value = _PartialHost(fixture);
    return true;
  } catch (_) {
    child?.dispose();
    await db.close();
    rethrow;
  }
}

Future<void> closeVisualParityBillPartialLink() {
  final fixture = _active;
  if (fixture == null) return Future<void>.value();
  // Busy dialog disables Cancel/Pop. QA teardown removes only its owned sibling.
  visualParityBillPartialLinkOverlay.value = null;
  if (!fixture.mounted) unawaited(fixture.disposeOnce());
  return fixture.closed.future;
}

class _PartialFixture {
  _PartialFixture(this.db, this.container, this.transactions, this.links,
      this.bill, this.baseline, this.key);
  final AppDatabase db;
  final ProviderContainer container;
  final _ActualTransactions transactions;
  final _PartialLinks links;
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
      await db.customSelect('SELECT 1').get();
      final after = await _snapshot(db);
      validateBillPartialSqlDelta(baseline, after, transactions.genuine?.id);
      if (links.postCommit != null && after != links.postCommit) {
        throw StateError('partial_child_changed_after_first_commit');
      }
      _lastReceipt = {
        ...visualParityBillPartialLinkReceipt(),
        'postCommitSqlUnchanged': true,
        'baselineDeltaValidated': true
      };
      _event('${key}PostCommitSqlUnchanged');
    } finally {
      container.dispose();
      await db.close();
      if (identical(_active, this)) {
        _active = null;
        visualParityBillPartialLinkOverlay.value = null;
      }
      _event('${key}Closed');
      closed.complete();
    }
  }
}

class _PartialHost extends StatefulWidget {
  const _PartialHost(this.fixture);
  final _PartialFixture fixture;
  @override
  State<_PartialHost> createState() => _PartialHostState();
}

class _PartialHostState extends State<_PartialHost> {
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
                  builder: (_) => _PartialLaunch(widget.fixture)))));
}

class _PartialLaunch extends StatefulWidget {
  const _PartialLaunch(this.fixture);
  final _PartialFixture fixture;
  @override
  State<_PartialLaunch> createState() => _PartialLaunchState();
}

class _PartialLaunchState extends State<_PartialLaunch> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await BillDetailsSheet.show(context, widget.fixture.bill);
      if (mounted) unawaited(closeVisualParityBillPartialLink());
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold();
}

void validateBillPartialSqlDelta(
    String baseline, String current, String? transactionId) {
  if (transactionId == null) {
    if (baseline != current) throw StateError('partial_changed_before_commit');
    return;
  }
  final before = jsonDecode(baseline) as Map<String, dynamic>;
  final after = jsonDecode(current) as Map<String, dynamic>;
  if (jsonEncode(before.keys.toList()) != jsonEncode(after.keys.toList())) {
    throw StateError('partial_table_set_changed');
  }
  for (final table in before.keys) {
    if (table == 'transactions') {
      if ((before[table] as List).isNotEmpty ||
          (after[table] as List).length != 1 ||
          after[table][0]['id'] != transactionId) {
        throw StateError('partial_transaction_count');
      }
    } else if (table == 'merchants') {
      final a = before[table] as List;
      final b = after[table] as List;
      if (a.length != b.length) throw StateError('partial_merchant_count');
      for (var i = 0; i < a.length; i++) {
        final old = Map<String, dynamic>.from(a[i] as Map)
          ..remove('last_seen_at');
        final now = Map<String, dynamic>.from(b[i] as Map)
          ..remove('last_seen_at');
        if (jsonEncode(old) != jsonEncode(now)) {
          throw StateError('partial_merchant_changed');
        }
      }
    } else if (jsonEncode(before[table]) != jsonEncode(after[table])) {
      throw StateError('partial_unexpected_table_change:$table');
    }
  }
}
