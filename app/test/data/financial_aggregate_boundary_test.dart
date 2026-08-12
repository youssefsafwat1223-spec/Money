import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';

  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

/// MALI-028 / MALI-047n / MALI-050n — proves the canonical repository
/// aggregates use half-open `[from, to)` windows and that account scope isolates
/// currency (a total is never a cross-currency sum).
void main() {
  late AppDatabase db;
  late DriftTransactionRepository transactions;
  late DriftAccountRepository accounts;

  final from = DateTime.utc(2026, 7); // 2026-07-01T00:00Z (inclusive)
  final to = DateTime.utc(2026, 8); //   2026-08-01T00:00Z (exclusive)

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    transactions = DriftTransactionRepository(db);
    accounts = DriftAccountRepository(db);
  });

  tearDown(() async => db.close());

  Future<void> put({
    required String id,
    required double amount,
    required DateTime occurredAt,
    required String accountId,
    String currency = 'SAR',
    TransactionTypeEntity type = TransactionTypeEntity.payment,
    String? categoryKey = 'groceries',
  }) async {
    await transactions.saveTransaction(
      transaction: TransactionEntity(
        id: id,
        amountMoney: Money.fromLegacyReal(amount, currency),
        currency: currency,
        type: type,
        source: TransactionSourceEntity.bank,
        occurredAt: occurredAt,
        rawMessage: id,
        parseConfidence: 1,
        status: TransactionStatus.confirmed,
        createdAt: occurredAt,
        updatedAt: occurredAt,
        accountId: accountId,
        rawMerchant: 'Boundary Market',
      ),
      categoryKey: categoryKey,
    );
  }

  Future<AccountEntity> account(String id, {String currency = 'SAR'}) {
    return accounts.create(
      AccountEntity(
        id: id,
        name: id,
        currency: currency,
        type: AccountType.bank,
        isDefault: id == 'sar',
        sortOrder: 0,
        createdAt: from,
        updatedAt: from,
      ),
    );
  }

  test('expenseTotalBetween is half-open [from, to)', () async {
    final acc = await account('sar');
    // Exactly at from → included (>= from).
    await put(
      id: 'at-from',
      amount: 10,
      occurredAt: from,
      accountId: acc.id,
    );
    // One second before to → included (< to).
    await put(
      id: 'before-to',
      amount: 20,
      occurredAt: to.subtract(const Duration(seconds: 1)),
      accountId: acc.id,
    );
    // Exactly at to → EXCLUDED (not < to) — the boundary belongs to next period.
    await put(
      id: 'at-to',
      amount: 40,
      occurredAt: to,
      accountId: acc.id,
    );

    expect(
        await transactions.expenseTotalBetween(
            from: from, to: to, currency: 'SAR'),
        Money(3000, 'SAR'));
    // The excluded boundary row is the first row of the adjacent window.
    final next = DateTime.utc(2026, 9);
    expect(
        await transactions.expenseTotalBetween(
            from: to, to: next, currency: 'SAR'),
        Money(4000, 'SAR'));
  });

  test('categoryBreakdown is half-open [from, to)', () async {
    final acc = await account('sar');
    await put(id: 'at-from', amount: 10, occurredAt: from, accountId: acc.id);
    await put(id: 'at-to', amount: 40, occurredAt: to, accountId: acc.id);

    final rows = await transactions.categoryBreakdown(
        from: from, to: to, currency: 'SAR');
    final total = Money.sum(rows.map((row) => row.total), 'SAR');
    expect(total, Money(1000, 'SAR')); // the at-to row is excluded
  });

  test('account scope isolates currency — totals are never cross-currency sums',
      () async {
    final sar = await account('sar', currency: 'SAR');
    final usd = await account('usd', currency: 'USD');
    final at = DateTime.utc(2026, 7, 15, 9);
    await put(
      id: 'sar-100',
      amount: 100,
      occurredAt: at,
      accountId: sar.id,
      currency: 'SAR',
    );
    await put(
      id: 'usd-200',
      amount: 200,
      occurredAt: at,
      accountId: usd.id,
      currency: 'USD',
    );

    // Each account's total stays in its own currency — never 300.
    expect(
      await transactions.expenseTotalBetween(
          from: from, to: to, currency: 'SAR', accountId: sar.id),
      Money(10000, 'SAR'),
    );
    expect(
      await transactions.expenseTotalBetween(
          from: from, to: to, currency: 'USD', accountId: usd.id),
      Money(20000, 'USD'),
    );

    // The per-currency grouping keeps them separate (no single labelled sum).
    final byCurrency =
        await transactions.currencyTotalsBetween(from: from, to: to);
    expect(byCurrency.length, 2);
    expect(
      byCurrency.firstWhere((c) => c.currency == 'SAR').expense,
      Money(10000, 'SAR'),
    );
    expect(
      byCurrency.firstWhere((c) => c.currency == 'USD').expense,
      Money(20000, 'USD'),
    );
  });
}
