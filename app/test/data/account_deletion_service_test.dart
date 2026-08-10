import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/sql_value_codec.dart';
import 'package:money_companion/data/repositories/account_deletion_service.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_bill_repository.dart';
import 'package:money_companion/data/repositories/drift_budget_repository.dart';
import 'package:money_companion/data/repositories/drift_card_repository.dart';
import 'package:money_companion/data/repositories/drift_goal_repository.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/bill_entity.dart';
import 'package:money_companion/domain/entities/budget_entity.dart';
import 'package:money_companion/domain/entities/card_entity.dart';
import 'package:money_companion/domain/entities/goal_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/engine/parser/card_network.dart';
import 'package:money_companion/domain/repositories/bill_repository.dart';
import 'package:money_companion/domain/usecases/account_deletion.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

// Wraps a real BillRepository but throws on delete — to prove the whole
// deletion rolls back atomically when a child mutation fails mid-way.
class _ThrowingOnDeleteBills implements BillRepository {
  _ThrowingOnDeleteBills(this._inner);
  final BillRepository _inner;
  @override
  Future<void> delete(String id) async => throw StateError('boom');
  @override
  Future<List<BillEntity>> getAll() => _inner.getAll();
  @override
  Future<List<BillEntity>> getDueBetween(
          {required DateTime from, required DateTime to}) =>
      _inner.getDueBetween(from: from, to: to);
  @override
  Future<BillEntity?> getById(String id) => _inner.getById(id);
  @override
  Future<BillEntity> save(BillEntity bill) => _inner.save(bill);
  @override
  Future<List<BillPaymentEntity>> getPayments(String billId) =>
      _inner.getPayments(billId);
  @override
  Future<BillPaymentEntity> recordPayment(BillPaymentEntity payment) =>
      _inner.recordPayment(payment);
  @override
  Future<BillPaymentEntity> createAndRecordPayment(
          {required BillEntity bill, required BillPaymentEntity payment}) =>
      _inner.createAndRecordPayment(bill: bill, payment: payment);
  @override
  Future<List<String>> deletePaymentForTransaction(String transactionId) =>
      _inner.deletePaymentForTransaction(transactionId);
  @override
  Future<void> deletePayment(String paymentId) =>
      _inner.deletePayment(paymentId);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late PlanningOutboxQueue queue;
  late DriftAccountRepository accounts;
  late DriftCardRepository cards;
  late DriftBudgetRepository budgets;
  late DriftGoalRepository goals;
  late DriftBillRepository bills;
  late FinancialAccountDeletionService service;
  late String catId; // a real seeded category (budgets.category_id has an FK)
  late String seededAccountId; // the default account the DB seeds on open

  final now = DateTime.utc(2026, 7, 1);

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    queue = PlanningOutboxQueue(
      db: db,
      isSyncEnabled: (_) => true,
      getAuthUserId: () async => 'user-1',
    );
    accounts = DriftAccountRepository(db, outboxQueue: queue);
    cards = DriftCardRepository(db, outboxQueue: queue);
    budgets = DriftBudgetRepository(db, outboxQueue: queue);
    goals = DriftGoalRepository(db, outboxQueue: queue);
    bills = DriftBillRepository(db, outboxQueue: queue);
    service = FinancialAccountDeletionService(
      db: db,
      accounts: accounts,
      cards: cards,
      budgets: budgets,
      goals: goals,
      bills: bills,
    );
    catId = (await db
            .customSelect('SELECT id FROM categories LIMIT 1;')
            .getSingle())
        .read<String>('id');
    seededAccountId = (await accounts.getAll()).single.id;
  });

  tearDown(() => db.close());

  Future<AccountEntity> account(String id, {String currency = 'SAR'}) =>
      accounts.create(AccountEntity(
        id: id,
        name: 'Acc $id',
        currency: currency,
        type: AccountType.bank,
        isDefault: false,
        sortOrder: 0,
        createdAt: now,
        updatedAt: now,
        initialBalanceMoney: Money(0, currency),
        currentBalanceMoney: Money(0, currency),
      ));

  Future<void> card(String id, String accountId) => cards.create(CardEntity(
        id: id,
        accountId: accountId,
        last4: '4242',
        network: CardNetwork.visa,
        source: CardSource.manual,
        createdAt: now,
        updatedAt: now,
      ));

  Future<void> budget(String id, String accountId) => budgets.save(BudgetEntity(
        id: id,
        categoryId: catId,
        amount: 500,
        period: BudgetPeriod.monthly,
        startDate: now,
        isActive: true,
        lastNotifiedSpentAmount: 0,
        lastNotifiedPeriodStart: DateTime.utc(2000),
        accountId: accountId,
      ));

  Future<void> goal(String id, String accountId, {double saved = 250}) =>
      goals.save(GoalEntity(
        id: id,
        name: 'Goal $id',
        targetAmount: 1000,
        savedAmount: saved,
        vaultSkin: 'default',
        status: 'active',
        createdAt: now,
        accountId: accountId,
      ));

  Future<void> bill(String id, String accountId, {String currency = 'SAR'}) =>
      bills.save(BillEntity(
        id: id,
        name: 'Bill $id',
        amount: 99,
        currency: currency,
        type: BillType.subscription,
        frequency: BillFrequency.monthly,
        nextDueDate: now,
        reminderOn: true,
        isConfirmed: true,
        createdAt: now,
        accountId: accountId,
      ));

  Future<void> txn(String id, String accountId) => db.customStatement(
        "INSERT INTO transactions(id, amount, currency, type, source, "
        "occurred_at, raw_message, parse_confidence, status, created_at, "
        "updated_at, account_id) VALUES ('$id', 10, 'SAR', 'payment', 'bank', "
        "'${dateTimeToSql(now)}', 'raw', 1.0, 'confirmed', "
        "'${dateTimeToSql(now)}', '${dateTimeToSql(now)}', '$accountId');",
      );

  Future<int> count(String sql) async =>
      (await db.customSelect('SELECT COUNT(*) AS n FROM $sql;').getSingle())
          .read<int>('n');

  Future<void> clearOutbox() =>
      db.customStatement('DELETE FROM planning_sync_outbox;');

  test('plan reports the exact dependency impact without mutating', () async {
    final keep = await account('keep');
    final del = await account('del');
    await card('c1', del.id);
    await budget('b1', del.id);
    await goal('g1', del.id);
    await bill('s1', del.id);
    await txn('t1', del.id);
    await txn('t2', del.id);

    final impact = await service.plan(del.id);

    expect(impact.transactionsToDetach, 2);
    expect(impact.cardsToArchive, 1);
    expect(impact.budgetsToArchive, 1);
    expect(impact.goals.single.id, 'g1');
    expect(impact.subscriptions.single.id, 's1');
    expect(impact.successorCandidates.map((a) => a.id), contains(keep.id));
    expect(impact.requiresDecision, isTrue);
    // Nothing changed.
    expect(await count("cards WHERE deleted_at IS NULL"), 1);
    expect(
        await count("accounts WHERE id = '${del.id}' AND deleted_at IS NULL"),
        1);
  });

  test(
      'per-relation policy: detach tx, archive card/budget, archive goal & sub',
      () async {
    await account('keep');
    final del = await account('del');
    await card('c1', del.id);
    await budget('b1', del.id);
    await goal('g1', del.id);
    await bill('s1', del.id);
    await txn('t1', del.id);
    await clearOutbox();

    final result = await service.execute(AccountDeletionRequest(
      accountId: del.id,
      subscriptionChoices: {'s1': const AccountReassignmentChoice.archive()},
      // g1 omitted -> archive by default
    ));

    // Transactions: detached to NULL, history preserved.
    expect(result.transactionsDetached, 1);
    expect(await count("transactions WHERE account_id IS NULL"), 1);
    expect(await count('transactions'), 1);
    // Card: archived (still holds account_id; soft-deleted).
    expect(result.cardsArchived, 1);
    expect(await count("cards WHERE deleted_at IS NOT NULL"), 1);
    expect(await count("cards WHERE id='c1' AND account_id='${del.id}'"), 1);
    // Budget: archived (deleted_at + is_active=0), never NULL-ed.
    expect(result.budgetsArchived, 1);
    expect(
        await count("budgets WHERE deleted_at IS NOT NULL AND is_active=0"), 1);
    expect(await count("budgets WHERE account_id IS NULL"), 0);
    // Goal: archived (status='archived'), never NULL-ed.
    expect(result.goalsArchived, 1);
    expect(
        await count("goals WHERE deleted_at IS NOT NULL AND status='archived'"),
        1);
    expect(await count("goals WHERE account_id IS NULL"), 0);
    // Subscription: archived (cancelled).
    expect(result.subscriptionsArchived, 1);
    expect(await count("subscriptions WHERE deleted_at IS NOT NULL"), 1);
    // Account tombstoned.
    expect(
        await count("accounts WHERE id='${del.id}' AND deleted_at IS NOT NULL"),
        1);
    // Every synced child change is mirrored to the outbox.
    expect(await count("planning_sync_outbox WHERE operation='delete'"),
        greaterThanOrEqualTo(4)); // card, budget, goal, sub, account
  });

  test('goals and subscriptions reassign to a currency-compatible successor',
      () async {
    final keep = await account('keep'); // SAR
    final del = await account('del'); // SAR
    await goal('g1', del.id, saved: 700);
    await bill('s1', del.id);

    final result = await service.execute(AccountDeletionRequest(
      accountId: del.id,
      goalChoices: {'g1': AccountReassignmentChoice.reassign(keep.id)},
      subscriptionChoices: {'s1': AccountReassignmentChoice.reassign(keep.id)},
    ));

    expect(result.goalsReassigned, 1);
    expect(result.subscriptionsReassigned, 1);
    // Goal survives, active, moved to successor with progress intact.
    final g = await goals.getById('g1');
    expect(g, isNotNull);
    expect(g!.accountId, keep.id);
    expect(g.savedAmount, 700);
    // Subscription survives, moved to successor.
    final s = await bills.getById('s1');
    expect(s!.accountId, keep.id);
  });

  test('reassigning to a currency-incompatible account is blocked (no change)',
      () async {
    await account('keep'); // SAR (compatible, but not chosen)
    final usd = await account('usd', currency: 'USD');
    final del = await account('del'); // SAR
    await bill('s1', del.id, currency: 'SAR');

    await expectLater(
      service.execute(AccountDeletionRequest(
        accountId: del.id,
        subscriptionChoices: {
          's1': AccountReassignmentChoice.reassign(usd.id), // USD != SAR
        },
      )),
      throwsA(isA<AccountDeletionBlocked>()),
    );
    // Nothing changed.
    expect(await count("subscriptions WHERE deleted_at IS NULL"), 1);
    expect(
        await count("accounts WHERE id='${del.id}' AND deleted_at IS NULL"), 1);
  });

  test('an active subscription with no decision blocks deletion (fallback)',
      () async {
    await account('keep');
    final del = await account('del');
    await bill('s1', del.id);
    await card('c1', del.id);

    await expectLater(
      service.execute(AccountDeletionRequest(accountId: del.id)),
      throwsA(isA<AccountDeletionBlocked>()),
    );
    // Conservative fallback: NOTHING deleted, not even the card.
    expect(await count("cards WHERE deleted_at IS NULL"), 1);
    expect(await count("subscriptions WHERE deleted_at IS NULL"), 1);
    expect(
        await count("accounts WHERE id='${del.id}' AND deleted_at IS NULL"), 1);
  });

  test('deleting the last account is refused', () async {
    // The DB seeds exactly one default account on open — deleting it is
    // deleting the last account.
    expect((await accounts.getAll()).length, 1);
    await expectLater(
      service.execute(AccountDeletionRequest(accountId: seededAccountId)),
      throwsA(isA<StateError>()),
    );
  });

  test('deleting the default account promotes a successor (MALI-015 preserved)',
      () async {
    // The seeded account is the default; add a successor then delete the default.
    expect((await accounts.getById(seededAccountId))!.isDefault, isTrue);
    final keep = await account('keep');

    final result = await service.execute(
      AccountDeletionRequest(accountId: seededAccountId),
    );

    expect(result.successorDefaultAccountId, keep.id);
    expect((await accounts.getById(keep.id))!.isDefault, isTrue);
  });

  test('a mid-deletion child failure rolls the ENTIRE deletion back', () async {
    await account('keep');
    final del = await account('del');
    await card('c1', del.id);
    await budget('b1', del.id);
    await goal('g1', del.id);
    await bill('s1', del.id);
    await txn('t1', del.id);

    final throwingService = FinancialAccountDeletionService(
      db: db,
      accounts: accounts,
      cards: cards,
      budgets: budgets,
      goals: goals,
      bills:
          _ThrowingOnDeleteBills(bills), // bill archive throws mid-transaction
    );

    await expectLater(
      throwingService.execute(AccountDeletionRequest(
        accountId: del.id,
        subscriptionChoices: {'s1': const AccountReassignmentChoice.archive()},
      )),
      throwsA(isA<StateError>()),
    );

    // Full rollback: cards/budgets/goals NOT archived, tx still attached,
    // account still alive.
    expect(await count("cards WHERE deleted_at IS NULL"), 1);
    expect(await count("budgets WHERE deleted_at IS NULL"), 1);
    expect(
        await count("goals WHERE deleted_at IS NULL AND status='active'"), 1);
    expect(await count("subscriptions WHERE deleted_at IS NULL"), 1);
    expect(await count("transactions WHERE account_id='${del.id}'"), 1);
    expect(
        await count("accounts WHERE id='${del.id}' AND deleted_at IS NULL"), 1);
  });
}
