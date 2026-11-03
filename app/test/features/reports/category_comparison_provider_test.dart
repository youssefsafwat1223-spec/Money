import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/reports/reports_providers.dart';
import 'package:money_companion/features/transactions/transactions_providers.dart';

class _MemoryKeys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-test';
  @override
  Future<String?> readStoredKey() async => 'memory-test';
}

void main() {
  late AppDatabase db;
  late ProviderContainer container;
  late DriftTransactionRepository transactions;
  final from = DateTime(2026, 1, 11);
  final to = DateTime(2026, 1, 21);

  setUp(() async {
    db = await AppDatabase.open(executor: NativeDatabase.memory(),
        keyStore: _MemoryKeys());
    await initFeatureFlagService(db, installIdOverride: 'comparison-test');
    container = ProviderContainer(overrides: [appDatabaseProvider.overrideWithValue(db)]);
    container.read(transactionsDateRangeProvider.notifier).state =
        TransactionsDateRange(preset: TransactionsDatePreset.custom, from: from, to: to);
    final accounts = DriftAccountRepository(db);
    for (final id in ['main', 'other']) {
      await accounts.create(AccountEntity(id: id, name: id, currency: 'KWD',
          type: AccountType.bank, isDefault: id == 'main', sortOrder: 0,
          createdAt: from, updatedAt: from));
    }
    container.read(activeAccountIdProvider.notifier).state = 'main';
    transactions = DriftTransactionRepository(db);
  });
  tearDown(() async { container.dispose(); await db.close(); });

  Future<void> put(String id, int minor, {DateTime? at,
      String account = 'main', String currency = 'KWD', String category = 'groceries',
      TransactionTypeEntity type = TransactionTypeEntity.payment,
      TransactionStatus status = TransactionStatus.confirmed}) async {
    await transactions.saveTransaction(transaction: TransactionEntity(
      id: id, amountMoney: Money(minor, currency), currency: currency, type: type,
      source: TransactionSourceEntity.bank, occurredAt: at ?? DateTime(2026, 1, 15),
      rawMessage: id, rawMerchant: 'Merchant $id', parseConfidence: 1,
      status: status, createdAt: from, updatedAt: from, accountId: account,
    ), categoryKey: category);
  }

  test('comparison keeps exact scoped net category totals and exclusions', () async {
    final previous = DateTime(2026, 1, 5);
    await put('old-pay', 20000, at: previous);
    await put('old-refund', 750, at: previous, type: TransactionTypeEntity.refund);
    await put('pay', 12345);
    await put('refund', 345, type: TransactionTypeEntity.refund);
    for (final at in [previous, DateTime(2026, 1, 15)]) {
      await put('other-$at', 90000, at: at, account: 'other');
      await put('currency-$at', 90000, at: at, currency: 'SAR');
      await put('pending-$at', 90000, at: at, status: TransactionStatus.pending);
      await put('ignored-$at', 90000, at: at, status: TransactionStatus.ignored);
      await put('income-$at', 90000, at: at, type: TransactionTypeEntity.income);
      await put('transfer-$at', 90000, at: at, type: TransactionTypeEntity.transfer);
    }
    final section = (await container.read(reportsProvider.future)).monthly;
    final slice = section.topCategories.single;
    expect(section.total, Money(12000, 'KWD'));
    expect(slice.total, Money(12000, 'KWD'));
    expect(slice.refunds, Money(345, 'KWD'));
    expect(slice.previousTotal, Money(19250, 'KWD'));
    expect(slice.count, 2);
  });

  test('comparison uses the same exclusive period boundaries as the total', () async {
    await put('previous-start', 400, at: DateTime(2025, 12, 31));
    await put('too-old', 99000, at: DateTime(2025, 12, 30, 23, 59));
    await put('current-start', 700, at: from);
    await put('current-end-excluded', 99000, at: to);
    final section = (await container.read(reportsProvider.future)).monthly;
    expect(section.total, Money(700, 'KWD'));
    expect(section.prevTotal, Money(400, 'KWD'));
    expect(section.topCategories.single.previousTotal, Money(400, 'KWD'));
  });

  test('a new category has a measured zero baseline without borrowing another category', () async {
    await put('old-groceries', 20000, at: DateTime(2026, 1, 5));
    await put('new-restaurants', 1000, category: 'restaurants');
    final slice = (await container.read(reportsProvider.future)).monthly.topCategories.single;
    expect(slice.category.key, 'restaurants');
    expect(slice.previousTotal, Money.zero('KWD'));
    expect(slice.changeRatio, isNull);
  });

  test('refund dominated windows retain negative exact totals', () async {
    final previous = DateTime(2026, 1, 5);
    await put('old-payment', 100, at: previous);
    await put('old-refund', 500, at: previous, type: TransactionTypeEntity.refund);
    await put('payment', 500);
    await put('refund', 800, type: TransactionTypeEntity.refund);
    final slice = (await container.read(reportsProvider.future)).monthly.topCategories.single;
    expect(slice.total, Money(-300, 'KWD'));
    expect(slice.previousTotal, Money(-400, 'KWD'));
    expect(slice.changeRatio, isNull);
  });
}
