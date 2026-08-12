import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';

// MALI-026 (Phase-8 B8-3 §17/§18/§19/§24) — v30 non-planning read/write authority:
// a repo write dual-binds `_minor` (authoritative) + REAL (shadow) from ONE Money;
// a read reconstructs Money from `_minor`; a NULL required `_minor` fail-closes
// (never silently falls back to REAL); FX uses foreign_amount_minor + currency.

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late DriftTransactionRepository repo;
  late String accountId;

  setUp(() async {
    db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
    repo = DriftTransactionRepository(db);
    accountId = (await db.customSelect('SELECT id FROM accounts LIMIT 1;')
            .getSingle())
        .read<String>('id');
  });
  tearDown(() => db.close());

  Future<int?> rawMinor(String col, String id) async => (await db
          .customSelect("SELECT $col AS m FROM transactions WHERE id = '$id';")
          .getSingle())
      .readNullable<int>('m');

  Future<double?> rawReal(String col, String id) async => (await db
          .customSelect("SELECT $col AS r FROM transactions WHERE id = '$id';")
          .getSingle())
      .readNullable<double>('r');

  TransactionEntity tx(String id, Money amount,
          {Money? balanceAfter, Money? foreign, String? foreignCurrency}) =>
      TransactionEntity(
        id: id,
        amountMoney: amount,
        currency: amount.currency,
        accountId: accountId,
        type: TransactionTypeEntity.payment,
        source: TransactionSourceEntity.imported,
        occurredAt: DateTime.utc(2026, 3, 1),
        rawMessage: '',
        parseConfidence: 1,
        status: TransactionStatus.confirmed,
        balanceAfterMoney: balanceAfter,
        foreignMoney: foreign,
        foreignCurrency: foreignCurrency,
        createdAt: DateTime.utc(2026, 3, 1),
        updatedAt: DateTime.utc(2026, 3, 1),
      );

  test('§18/§19 a repo write dual-binds _minor (authority) + REAL (shadow)',
      () async {
    await repo.saveTransaction(
      transaction: tx('t1', Money.parse('19.99', 'EGP')),
      categoryKey: null,
    );
    expect(await rawMinor('amount_minor', 't1'), 1999); // authoritative int64
    expect(await rawReal('amount', 't1'), 19.99); // exact shadow
  });

  test('§17 read reconstructs Money from _minor (not REAL)', () async {
    await repo.saveTransaction(
      transaction: tx('t2', Money.parse('1.234', 'KWD')), // 3-dec
      categoryKey: null,
    );
    final read = (await repo.getById('t2'))!;
    expect(read.amountMoney.minorUnits, 1234);
    expect(read.amountMoney.currency, 'KWD');
  });

  test('§17 a NULL required _minor FAIL-CLOSES on read (no REAL fallback)',
      () async {
    await repo.saveTransaction(
      transaction: tx('t3', Money.parse('5.00', 'EGP')),
      categoryKey: null,
    );
    // Corrupt the invariant: authoritative minor gone, REAL shadow intact.
    await db.customStatement(
        "UPDATE transactions SET amount_minor = NULL WHERE id = 't3';");
    await expectLater(repo.getById('t3'), throwsA(anything));
  });

  test('§24 FX round-trips via foreign_amount_minor + foreign_currency',
      () async {
    await repo.saveTransaction(
      transaction: tx('t4', Money.parse('100.00', 'EGP'),
          foreign: Money.parse('3.750', 'KWD'), foreignCurrency: 'KWD'),
      categoryKey: null,
    );
    expect(await rawMinor('foreign_amount_minor', 't4'), 3750); // KWD 3-dec
    final read = (await repo.getById('t4'))!;
    expect(read.foreignMoney!.minorUnits, 3750);
    expect(read.foreignMoney!.currency, 'KWD');
  });

  test('§18 nullable money: absent → both columns NULL', () async {
    await repo.saveTransaction(
      transaction: tx('t5', Money.parse('9.00', 'EGP')), // no balance/foreign
      categoryKey: null,
    );
    expect(await rawMinor('balance_after_minor', 't5'), isNull);
    expect(await rawReal('balance_after', 't5'), isNull);
    expect(await rawMinor('foreign_amount_minor', 't5'), isNull);
  });
}
