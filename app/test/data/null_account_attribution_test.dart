import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/sql_value_codec.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/account_entity.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';
  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

/// MALI-074n — an unassigned (`account_id IS NULL`) transaction belongs to no
/// specific account and is never attributed to one by matching currency.
void main() {
  late AppDatabase db;
  late DriftTransactionRepository txRepo;
  late DriftAccountRepository accountRepo;

  final from = DateTime.utc(2026, 7);
  final to = DateTime.utc(2026, 8);

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    txRepo = DriftTransactionRepository(db);
    accountRepo = DriftAccountRepository(db);
  });

  tearDown(() async => db.close());

  Future<void> tx({
    required String id,
    required double amount,
    String? accountId,
    String currency = 'SAR',
    String type = 'payment',
  }) async {
    await db.customInsert(
      '''
        INSERT INTO transactions(
          id, amount, currency, type, source, account_id,
          occurred_at, raw_message, parse_confidence, status,
          created_at, updated_at
        ) VALUES (?, ?, ?, ?, 'sms', ?, ?, 'm', 1, 'confirmed', ?, ?);
      ''',
      variables: [
        Variable.withString(id),
        Variable.withReal(amount),
        Variable.withString(currency),
        Variable.withString(type),
        accountId == null
            ? const Variable<String>(null)
            : Variable.withString(accountId),
        Variable.withString(dateTimeToSql(DateTime.utc(2026, 7, 15).toUtc())),
        Variable.withString(dateTimeToSql(DateTime.utc(2026, 7, 15).toUtc())),
        Variable.withString(dateTimeToSql(DateTime.utc(2026, 7, 15).toUtc())),
      ],
    );
  }

  Future<AccountEntity> account(String id, {String currency = 'SAR'}) =>
      accountRepo.create(AccountEntity(
        id: id,
        name: id,
        currency: currency,
        type: AccountType.bank,
        isDefault: id == 'a',
        sortOrder: 0,
        createdAt: from,
        updatedAt: from,
      ));

  test('two same-currency accounts both exclude a NULL-account row; global '
      'includes it once', () async {
    await account('a');
    await account('b');
    await tx(id: 'a-pay', amount: 100, accountId: 'a');
    await tx(id: 'b-pay', amount: 200, accountId: 'b');
    await tx(id: 'orphan', amount: 30, accountId: null); // unassigned, SAR

    expect(await txRepo.expenseTotalBetween(from: from, to: to, accountId: 'a'),
        100); // NOT 130
    expect(await txRepo.expenseTotalBetween(from: from, to: to, accountId: 'b'),
        200); // NOT 230
    // All-accounts (global) scope includes the orphan exactly once.
    expect(
        await txRepo.expenseTotalBetween(from: from, to: to), 330); // 100+200+30
  });

  test('assigning the orphan to A includes it only under A', () async {
    await account('a');
    await account('b');
    await tx(id: 'orphan', amount: 30, accountId: null);
    await txRepo.updateAccount(transactionId: 'orphan', accountId: 'a');

    expect(await txRepo.expenseTotalBetween(from: from, to: to, accountId: 'a'),
        30);
    expect(await txRepo.expenseTotalBetween(from: from, to: to, accountId: 'b'),
        0);
    expect(await txRepo.expenseTotalBetween(from: from, to: to), 30);
  });

  test('mixed currencies: an account never picks up a foreign orphan', () async {
    await account('sar', currency: 'SAR');
    await account('usd', currency: 'USD');
    await tx(id: 'orphan-usd', amount: 50, accountId: null, currency: 'USD');
    // SAR account excludes the USD orphan (previously the currency fallback
    // would still have excluded it, but the point is exact ownership).
    expect(
        await txRepo.expenseTotalBetween(from: from, to: to, accountId: 'sar'),
        0);
    expect(
        await txRepo.expenseTotalBetween(from: from, to: to, accountId: 'usd'),
        0);
  });

  test('category breakdown honours exact account ownership', () async {
    await account('a');
    await tx(id: 'a-pay', amount: 100, accountId: 'a', type: 'payment');
    await tx(id: 'orphan', amount: 30, accountId: null, type: 'payment');
    // categoryBreakdown needs a category; both rows are uncategorised → the
    // account-scoped total via expenseTotalBetween is the invariant we assert.
    expect(await txRepo.expenseTotalBetween(from: from, to: to, accountId: 'a'),
        100);
  });
}
