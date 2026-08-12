import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/finance/money.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';
  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

void main() {
  late AppDatabase db;
  late DriftAccountRepository accounts;
  late DriftTransactionRepository txRepo;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    accounts = DriftAccountRepository(db);
    txRepo = DriftTransactionRepository(db);
  });
  tearDown(() async => db.close());

  Future<void> confirmedTx({
    required String id,
    required String accountId,
    required String type,
    required double amount,
    double? balanceAfter,
  }) async {
    await db.customStatement(
      '''
        INSERT INTO transactions(
          id, amount, currency, type, source, account_id, balance_after,
          occurred_at, raw_message, parse_confidence, status,
          created_at, updated_at
        ) VALUES (
          '$id', $amount, 'SAR', '$type', 'sms', '$accountId',
          ${balanceAfter ?? 'NULL'},
          '2026-07-20T10:00:00.000Z', 'm', 1.0, 'confirmed',
          '2026-07-20T10:00:00.000Z', '2026-07-20T10:00:00.000Z'
        );
      ''',
    );
    await backfillNonPlanningMoneyV30(db);
  }

  test('combined totals exclude flagged accounts; per-account totals do not',
      () async {
    final normal = await accounts.create(AccountEntity(
      id: '',
      name: 'A',
      currency: 'SAR',
      type: AccountType.bank,
      isDefault: true,
      sortOrder: 0,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    ));
    final excluded = await accounts.create(AccountEntity(
      id: '',
      name: 'B',
      currency: 'SAR',
      type: AccountType.bank,
      isDefault: false,
      sortOrder: 1,
      excludeFromTotals: true,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    ));

    await confirmedTx(
        id: 't1', accountId: normal.id, type: 'payment', amount: 100);
    await confirmedTx(
        id: 't2', accountId: excluded.id, type: 'payment', amount: 40);
    await confirmedTx(
        id: 't3', accountId: normal.id, type: 'income', amount: 500);
    await confirmedTx(
        id: 't4', accountId: excluded.id, type: 'income', amount: 999);

    final from = DateTime.utc(2026, 7, 1);
    final to = DateTime.utc(2026, 7, 31);

    // Combined (accountId null) excludes the flagged account.
    expect(
        await txRepo.expenseTotalBetween(from: from, to: to, currency: 'SAR'),
        Money(10000, 'SAR'));
    expect(await txRepo.incomeTotalBetween(from: from, to: to, currency: 'SAR'),
        Money(50000, 'SAR'));

    // Per-account totals are unaffected — drilling into the flagged account
    // still reports its own numbers (the flag keeps it out of combined totals,
    // not out of its own detail view).
    expect(
        await txRepo.expenseTotalBetween(
            from: from, to: to, currency: 'SAR', accountId: excluded.id),
        Money(4000, 'SAR'));
    expect(
        await txRepo.incomeTotalBetween(
            from: from, to: to, currency: 'SAR', accountId: excluded.id),
        Money(99900, 'SAR'));

    // Currency totals (always combined) exclude the flagged account.
    final totals = await txRepo.currencyTotalsBetween(from: from, to: to);
    final sar = totals.firstWhere((t) => t.currency == 'SAR');
    expect(sar.expense, Money(10000, 'SAR'));
    expect(sar.income, Money(50000, 'SAR'));
  });

  test('latestBalanceAfter combined skips flagged accounts', () async {
    final normal = await accounts.create(AccountEntity(
      id: '',
      name: 'A',
      currency: 'SAR',
      type: AccountType.bank,
      isDefault: true,
      sortOrder: 0,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    ));
    final excluded = await accounts.create(AccountEntity(
      id: '',
      name: 'B',
      currency: 'SAR',
      type: AccountType.bank,
      isDefault: false,
      sortOrder: 1,
      excludeFromTotals: true,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    ));
    await confirmedTx(
        id: 't1',
        accountId: normal.id,
        type: 'payment',
        amount: 1,
        balanceAfter: 300);
    // Newer, but on the excluded account → must not be picked for combined.
    await db.customStatement(
      '''
        INSERT INTO transactions(
          id, amount, currency, type, source, account_id, balance_after,
          occurred_at, raw_message, parse_confidence, status,
          created_at, updated_at
        ) VALUES (
          't2', 1, 'SAR', 'payment', 'sms', '${excluded.id}', 9999,
          '2026-07-25T10:00:00.000Z', 'm', 1.0, 'confirmed',
          '2026-07-25T10:00:00.000Z', '2026-07-25T10:00:00.000Z'
        );
      ''',
    );
    await backfillNonPlanningMoneyV30(db);
    expect(await txRepo.latestBalanceAfter(), Money(30000, 'SAR'));
    expect(await txRepo.latestBalanceAfter(accountId: excluded.id),
        Money(999900, 'SAR'));
  });
}
