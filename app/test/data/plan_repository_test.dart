import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';
import 'package:money_companion/data/db/sql_value_codec.dart';
import 'package:money_companion/data/repositories/drift_plan_repository.dart';
import 'package:money_companion/domain/entities/plan_entity.dart';
import 'package:money_companion/domain/finance/money.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';
  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

void main() {

  late AppDatabase db;
  late DriftPlanRepository repo;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    repo = DriftPlanRepository(db);
  });

  tearDown(() async => db.close());

  Future<void> insertTxn({
    required String id,
    required double amount,
    required String type,
    required DateTime occurredAt,
    required String status,
    String? accountId,
    String? cardLast4,
  }) async {
    await db.customInsert(
      '''
        INSERT INTO transactions(
          id, amount, currency, type, source, account_id, card_last4,
          occurred_at, raw_message, parse_confidence, status, created_at, updated_at
        ) VALUES (?, ?, 'SAR', ?, 'unknown', ?, ?, ?, 'm', 1, ?, ?, ?);
      ''',
      variables: [
        Variable.withString(id),
        Variable.withReal(amount),
        Variable.withString(type),
        accountId == null
            ? const Variable<String>(null)
            : Variable.withString(accountId),
        cardLast4 == null
            ? const Variable<String>(null)
            : Variable.withString(cardLast4),
        Variable.withString(dateTimeToSql(occurredAt.toUtc())),
        Variable.withString(status),
        Variable.withString(dateTimeToSql(occurredAt.toUtc())),
        Variable.withString(dateTimeToSql(occurredAt.toUtc())),
      ],
    );
    await backfillNonPlanningMoneyV30(db);
  }

  PlanEntity plan({
    List<String> accounts = const [],
    List<String> cards = const [],
  }) =>
      PlanEntity(
        id: 'plan-1',
        name: 'رحلة',
        budgetAmountMoney: Money.fromLegacyReal(5000, 'SAR'),
        currency: 'SAR',
        startDate: DateTime.utc(2026, 6, 1),
        endDate: DateTime.utc(2026, 6, 10, 23, 59, 59),
        accountIds: accounts,
        cardLast4s: cards,
        status: PlanStatus.active,
        createdAt: DateTime.utc(2026, 6, 1),
      );

  test('spentForPlan counts only matching account/card within the date range',
      () async {
    await insertTxn(
        id: 't1',
        amount: 100,
        type: 'payment',
        occurredAt: DateTime.utc(2026, 6, 5),
        status: 'confirmed',
        accountId: 'acc1');
    await insertTxn(
        id: 't2',
        amount: 50,
        type: 'payment',
        occurredAt: DateTime.utc(2026, 6, 5),
        status: 'confirmed',
        accountId: 'acc2',
        cardLast4: '7640'); // card match
    await insertTxn(
        id: 't3',
        amount: 200,
        type: 'payment',
        occurredAt: DateTime.utc(2026, 6, 5),
        status: 'confirmed',
        accountId: 'acc2',
        cardLast4: '1111'); // no match
    await insertTxn(
        id: 't4',
        amount: 70,
        type: 'payment',
        occurredAt: DateTime.utc(2026, 6, 20), // out of range
        status: 'confirmed',
        accountId: 'acc1');
    await insertTxn(
        id: 't5',
        amount: 30,
        type: 'income', // not an expense
        occurredAt: DateTime.utc(2026, 6, 5),
        status: 'confirmed',
        accountId: 'acc1');

    final spent =
        await repo.spentForPlan(plan(accounts: ['acc1'], cards: ['7640']));
    expect(spent, Money(15000, 'SAR')); // t1 (account) + t2 (card)
  });

  test('spentForPlan with no account/card counts all expenses in range',
      () async {
    await insertTxn(
        id: 'a',
        amount: 100,
        type: 'payment',
        occurredAt: DateTime.utc(2026, 6, 5),
        status: 'confirmed',
        accountId: 'x');
    await insertTxn(
        id: 'b',
        amount: 40,
        type: 'withdrawal',
        occurredAt: DateTime.utc(2026, 6, 6),
        status: 'confirmed',
        accountId: 'y');
    await insertTxn(
        id: 'c',
        amount: 999,
        type: 'payment',
        occurredAt: DateTime.utc(2026, 7, 1), // out of range
        status: 'confirmed',
        accountId: 'z');

    final spent = await repo.spentForPlan(plan());
    expect(spent, Money(14000, 'SAR'));
  });

  test('save then getAll round-trips account/card lists', () async {
    await repo.save(plan(accounts: ['acc1', 'acc2'], cards: ['7640']));
    final all = await repo.getAll();
    expect(all, hasLength(1));
    expect(all.first.accountIds, ['acc1', 'acc2']);
    expect(all.first.cardLast4s, ['7640']);
    expect(all.first.name, 'رحلة');
  });
}
