import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';

  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

TransactionEntity _tx(String id, Money amount, DateTime at,
        {Money? foreign, String? foreignCurrency, String merchant = 'SHOP'}) =>
    TransactionEntity(
      id: id,
      amountMoney: amount,
      currency: 'SAR',
      type: TransactionTypeEntity.payment,
      source: TransactionSourceEntity.card,
      occurredAt: at,
      rawMessage: id,
      rawMerchant: merchant,
      parseConfidence: 0.9,
      status: TransactionStatus.confirmed,
      direction: TransactionDirectionEntity.debit,
      createdAt: at,
      updatedAt: at,
      foreignMoney: foreign,
      foreignCurrency: foreignCurrency,
    );

/// A CONFIRMED amount-0 awaitingFx row (local_auto_confirm_v2 foreign-unpriced)
/// must not change any sum; this pins exactly which aggregates it DOES touch.
void main() {
  late AppDatabase db;
  late DriftTransactionRepository repo;
  final from = DateTime.utc(2026, 6, 1);
  final to = DateTime.utc(2026, 7, 1);

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    repo = DriftTransactionRepository(db);
    await repo.saveTransaction(
        transaction: _tx('a', Money.parse('100.00', 'SAR'),
            DateTime.utc(2026, 6, 10, 12)),
        categoryKey: 'shopping');
    await repo.saveTransaction(
        transaction: _tx('b', Money.parse('50.00', 'SAR'),
            DateTime.utc(2026, 6, 11, 12)),
        categoryKey: 'shopping');
  });

  tearDown(() async => db.close());

  Future<void> addAwaiting({DateTime? at}) => repo
      .saveTransaction(
          transaction: _tx('z', Money.zero('SAR'),
              at ?? DateTime.utc(2026, 6, 10, 15),
              foreign: Money.parse('99.00', 'USD'), foreignCurrency: 'USD'),
          categoryKey: 'shopping')
      .then((_) {});

  test('the row is awaitingFx', () {
    expect(
        _tx('z', Money.zero('SAR'), DateTime.utc(2026, 6, 10),
                foreign: Money.parse('1.00', 'USD'), foreignCurrency: 'USD')
            .pricingState,
        TransactionPricingState.awaitingFx);
  });

  test('sums are unchanged by a confirmed amount-0 row', () async {
    final before = await repo.currencyTotalsBetween(from: from, to: to);
    final expenseBefore = await repo.expenseTotalBetween(from: from, to: to, currency: 'SAR');
    await addAwaiting();
    final after = await repo.currencyTotalsBetween(from: from, to: to);
    expect(after.single.expense, before.single.expense);
    expect(after.single.expense, Money.parse('150.00', 'SAR'));
    expect(await repo.expenseTotalBetween(from: from, to: to, currency: 'SAR'), expenseBefore);
    final days = await repo.dailyExpenseTotals(
        from: from, to: to, currency: 'SAR');
    expect(days.map((d) => d.total.minorUnits).reduce((a, b) => a + b), 15000);
  });

  test('row counts ignore the awaitingFx row; a priced row counts normally',
      () async {
    await addAwaiting();
    var categories =
        await repo.categoryBreakdown(from: from, to: to, currency: 'SAR');
    expect(categories.single.total, Money.parse('150.00', 'SAR'));
    expect(categories.single.count, 2);
    final merchants =
        await repo.merchantBreakdown(from: from, to: to, currency: 'SAR');
    expect(merchants.single.count, 2);

    // The user prices it: amount > 0 now, so it is an ordinary row.
    await db.customStatement(
        "UPDATE transactions SET amount_minor = 3700, amount = 37.0 "
        "WHERE id = 'z'");
    categories =
        await repo.categoryBreakdown(from: from, to: to, currency: 'SAR');
    expect(categories.single.count, 3);
    expect(categories.single.total, Money.parse('187.00', 'SAR'));
  });

  test('card counts ignore the awaitingFx row', () async {
    await db.customStatement(
        "UPDATE transactions SET card_last4 = '1234'");
    await repo.saveTransaction(
        transaction: _tx('z', Money.zero('SAR'), DateTime.utc(2026, 6, 10, 15),
                foreign: Money.parse('99.00', 'USD'), foreignCurrency: 'USD')
            .copyWith(cardLast4: '1234'),
        categoryKey: 'shopping');
    final cards = await repo.getCardSummaries();
    expect(cards.single.count, 2);
  });

  test('a day holding ONLY the awaitingFx row adds no day to daily averages',
      () async {
    await addAwaiting(at: DateTime.utc(2026, 6, 20, 12));
    final days = await repo.dailyExpenseTotals(
        from: from, to: to, currency: 'SAR');
    expect(days.length, 2);
  });

  test('recurring detection is unchanged by an awaitingFx row', () async {
    Future<void> add(String id, String m, DateTime at, Money amt) =>
        repo.saveTransaction(
            transaction: _tx(id, amt, at, merchant: m),
            categoryKey: 'bills');
    await add('n1', 'NETFLIX', DateTime.utc(2026, 1, 10), Money.parse('56.00', 'SAR'));
    await add('n2', 'NETFLIX', DateTime.utc(2026, 2, 10), Money.parse('56.00', 'SAR'));
    await repo.saveTransaction(
        transaction: _tx('n3', Money.zero('SAR'), DateTime.utc(2026, 3, 10),
            merchant: 'NETFLIX',
            foreign: Money.parse('15.00', 'USD'),
            foreignCurrency: 'USD'),
        categoryKey: 'bills');
    final netflix = (await repo.recurringCandidates())
        .firstWhere((r) => r.name == 'NETFLIX');
    expect(netflix.monthsSeen, 2);
    expect(netflix.estimatedAmountMoney, Money.parse('56.00', 'SAR'));
  });
}
