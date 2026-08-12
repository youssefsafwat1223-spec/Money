import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';
import 'package:money_companion/data/db/sql_value_codec.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_plan_repository.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/plan_entity.dart';
import 'package:money_companion/domain/finance/currency_scale.dart';
import 'package:money_companion/domain/finance/financial_semantics.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/finance/plan_scope.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';
  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

/// MALI-048n — the canonical plan-spending contract.
void main() {

  late AppDatabase db;
  late DriftPlanRepository repo;
  late DriftAccountRepository accounts;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    repo = DriftPlanRepository(db);
    accounts = DriftAccountRepository(db);
  });

  tearDown(() async => db.close());

  Future<void> tx({
    required String id,
    required double amount,
    String type = 'payment',
    String status = 'confirmed',
    String currency = 'SAR',
    String? accountId,
    String? cardLast4,
    DateTime? occurredAt,
  }) async {
    await db.customInsert(
      '''
        INSERT INTO transactions(
          id, amount, currency, type, source, account_id, card_last4,
          occurred_at, raw_message, parse_confidence, status, created_at, updated_at
        ) VALUES (?, ?, ?, ?, 'unknown', ?, ?, ?, 'm', 1, ?, ?, ?);
      ''',
      variables: [
        Variable.withString(id),
        Variable.withReal(amount),
        Variable.withString(currency),
        Variable.withString(type),
        accountId == null
            ? const Variable<String>(null)
            : Variable.withString(accountId),
        cardLast4 == null
            ? const Variable<String>(null)
            : Variable.withString(cardLast4),
        Variable.withString(
            dateTimeToSql((occurredAt ?? DateTime(2026, 6, 5)).toUtc())),
        Variable.withString(status),
        Variable.withString(dateTimeToSql(DateTime.utc(2026, 6, 5).toUtc())),
        Variable.withString(dateTimeToSql(DateTime.utc(2026, 6, 5).toUtc())),
      ],
    );
    await backfillNonPlanningMoneyV30(db);
  }

  PlanEntity plan({
    List<String> accountIds = const [],
    List<String> cards = const [],
    String currency = 'SAR',
  }) =>
      PlanEntity(
        id: 'plan-1',
        name: 'رحلة',
        budgetAmountMoney: Money.fromLegacyReal(
            5000, isSupportedCurrency(currency) ? currency : 'SAR'),
        currency: currency,
        startDate: DateTime(2026, 6, 1),
        endDate: DateTime(2026, 6, 10, 23, 59, 59),
        accountIds: accountIds,
        cardLast4s: cards,
        status: PlanStatus.active,
        createdAt: DateTime.utc(2026, 6, 1),
      );

  test('scope model: empty selection is the explicit all-expenses scope', () {
    expect(plan().scopeMode, PlanScopeMode.allExpenses);
    expect(plan(accountIds: ['a']).scopeMode, PlanScopeMode.selected);
    expect(plan(cards: ['1']).scopeMode, PlanScopeMode.selected);
    expect(plan(currency: '  ').hasValidCurrency, isFalse);
    expect(plan().hasValidCurrency, isTrue);
  });

  test('plan currency isolates — a SAR plan never sums EGP/USD', () async {
    final p = plan(accountIds: ['acc']);
    await repo.save(p);
    await tx(id: 'sar', amount: 100, accountId: 'acc', currency: 'SAR');
    await tx(id: 'usd', amount: 999, accountId: 'acc', currency: 'USD');
    // Even a manually-linked foreign-currency row must not be summed.
    await tx(id: 'egp-link', amount: 500, accountId: 'other', currency: 'EGP');
    await repo.linkTransactionToPlan(planId: p.id, transactionId: 'egp-link');

    expect(await repo.spentForPlan(p), 100);
  });

  test('refund nets expense; withdrawal counts; income/transfer excluded',
      () async {
    await tx(id: 'pay', amount: 200, type: 'payment', accountId: 'acc');
    await tx(id: 'wd', amount: 40, type: 'withdrawal', accountId: 'acc');
    await tx(id: 'ref', amount: 50, type: 'refund', accountId: 'acc');
    await tx(id: 'inc', amount: 900, type: 'income', accountId: 'acc');
    await tx(id: 'xfer', amount: 700, type: 'transfer', accountId: 'acc');

    expect(await repo.spentForPlan(plan(accountIds: ['acc'])), 190); // 200+40-50
  });

  test('pending / ignored never count', () async {
    await tx(id: 'ok', amount: 100, accountId: 'acc');
    await tx(id: 'pending', amount: 30, status: 'pending', accountId: 'acc');
    await tx(id: 'ignored', amount: 60, status: 'ignored', accountId: 'acc');
    expect(await repo.spentForPlan(plan(accountIds: ['acc'])), 100);
  });

  test('half-open window: start included, endExclusive excluded', () async {
    await tx(
        id: 'at-start',
        amount: 10,
        accountId: 'acc',
        occurredAt: DateTime(2026, 6, 1));
    await tx(
        id: 'last-day',
        amount: 20,
        accountId: 'acc',
        occurredAt: DateTime(2026, 6, 10, 22));
    // 2026-06-11 00:00 (local) is the genuine exclusive bound → excluded.
    await tx(
        id: 'next-day',
        amount: 40,
        accountId: 'acc',
        occurredAt: DateTime(2026, 6, 11));
    expect(await repo.spentForPlan(plan(accountIds: ['acc'])), 30);
  });

  test('all-expenses scope applies the excluded-account policy; selected does '
      'not', () async {
    final normal = await accounts.create(AccountEntity(
      id: 'normal',
      name: 'N',
      currency: 'SAR',
      type: AccountType.bank,
      isDefault: true,
      sortOrder: 0,
      createdAt: DateTime.utc(2026, 6, 1),
      updatedAt: DateTime.utc(2026, 6, 1),
    ));
    final excluded = await accounts.create(AccountEntity(
      id: 'excluded',
      name: 'X',
      currency: 'SAR',
      type: AccountType.bank,
      isDefault: false,
      sortOrder: 1,
      excludeFromTotals: true,
      createdAt: DateTime.utc(2026, 6, 1),
      updatedAt: DateTime.utc(2026, 6, 1),
    ));
    await tx(id: 'n', amount: 100, accountId: normal.id);
    await tx(id: 'x', amount: 70, accountId: excluded.id);

    // All-expenses plan drops the flagged account.
    expect(await repo.spentForPlan(plan()), 100);
    // Explicitly selecting the flagged account overrides the policy.
    expect(await repo.spentForPlan(plan(accountIds: [excluded.id])), 70);
  });

  test('membership is a UNION of account and card scope', () async {
    await tx(id: 'by-account', amount: 100, accountId: 'acc1');
    await tx(id: 'by-card', amount: 50, accountId: 'acc2', cardLast4: '7640');
    await tx(id: 'neither', amount: 200, accountId: 'acc3', cardLast4: '1111');
    expect(
      await repo.spentForPlan(plan(accountIds: ['acc1'], cards: ['7640'])),
      150,
    );
  });

  test('blank currency fails closed to zero', () async {
    await tx(id: 't', amount: 100, accountId: 'acc');
    expect(await repo.spentForPlan(plan(accountIds: ['acc'], currency: ' ')),
        0);
    expect(
      await repo.transactionsForPlan(plan(accountIds: ['acc'], currency: ' ')),
      isEmpty,
    );
  });

  test('displayed transaction list nets to the same canonical total', () async {
    await tx(id: 'pay', amount: 200, type: 'payment', accountId: 'acc');
    await tx(id: 'ref', amount: 50, type: 'refund', accountId: 'acc');
    final p = plan(accountIds: ['acc']);
    final total = await repo.spentForPlan(p);
    final list = await repo.transactionsForPlan(p);
    final signedListSum = list.fold<double>(
      0,
      (s, t) => s + (t.type.name == 'refund' ? -t.amount : t.amount),
    );
    expect(list.map((t) => t.id), containsAll(['pay', 'ref']));
    expect(signedListSum, total);
    expect(total, 150);
  });

  test('large dataset (501 rows) is aggregated set-based, not folded', () async {
    for (var i = 0; i < 501; i++) {
      await tx(id: 'p$i', amount: 1, accountId: 'acc');
    }
    expect(await repo.spentForPlan(plan(accountIds: ['acc'])), 501);
  });

  test('canonical SQL signed amount matches the shared contract', () {
    // Guards against a plan re-implementing net-expense differently.
    expect(FinancialSql.netExpenseTypePredicate(),
        "type IN ('payment', 'withdrawal', 'refund')");
  });
}
