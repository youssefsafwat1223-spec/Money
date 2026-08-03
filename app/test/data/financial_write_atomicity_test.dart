import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_bill_repository.dart';
import 'package:money_companion/data/repositories/drift_goal_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/bill_entity.dart';
import 'package:money_companion/domain/entities/goal_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/features/capture/services/ledger_outbox_queue.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';

  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

LedgerOutboxQueue _ledgerQueue(AppDatabase db) {
  return LedgerOutboxQueue(
    db: db,
    isPushEnabled: () => true,
    getAuthUserId: () async => 'user-1',
  );
}

PlanningOutboxQueue _planningQueue(AppDatabase db) {
  return PlanningOutboxQueue(
    db: db,
    isSyncEnabled: (_) => true,
    getAuthUserId: () async => 'user-1',
  );
}

TransactionEntity _transaction(String id) {
  final now = DateTime.utc(2026, 7, 28, 12);
  return TransactionEntity(
    id: id,
    amount: 125,
    currency: 'SAR',
    type: TransactionTypeEntity.payment,
    source: TransactionSourceEntity.bank,
    occurredAt: now,
    rawMessage: 'Atomic transaction $id',
    parseConfidence: 1,
    status: TransactionStatus.confirmed,
    createdAt: now,
    updatedAt: now,
    rawMerchant: 'Atomic Store $id',
    direction: TransactionDirectionEntity.debit,
  );
}

GoalEntity _goal() {
  return GoalEntity(
    id: 'goal-atomic',
    name: 'Atomic goal',
    targetAmount: 1000,
    savedAmount: 100,
    vaultSkin: 'classic',
    status: 'active',
    createdAt: DateTime.utc(2026, 7, 28),
  );
}

BillEntity _bill() {
  return BillEntity(
    id: 'bill-atomic',
    name: 'Atomic installment',
    amount: 250,
    currency: 'SAR',
    type: BillType.installment,
    frequency: BillFrequency.monthly,
    nextDueDate: DateTime.utc(2026, 8, 1),
    reminderOn: true,
    isConfirmed: true,
    createdAt: DateTime.utc(2026, 7, 1),
    totalInstallments: 4,
    paidCount: 0,
  );
}

BillPaymentEntity _payment() {
  return BillPaymentEntity(
    id: 'payment-atomic',
    billId: 'bill-atomic',
    amount: 250,
    currency: 'SAR',
    periodStart: DateTime.utc(2026, 8, 1),
    periodEnd: DateTime.utc(2026, 8, 31),
    paidAt: DateTime.utc(2026, 8, 2),
    installmentIndex: 1,
  );
}

Future<int> _count(AppDatabase db, String table, String id) async {
  final row = await db
      .customSelect(
        "SELECT COUNT(*) AS total FROM $table WHERE id = '$id';",
      )
      .getSingle();
  return row.read<int>('total');
}

Future<int> _activeCount(AppDatabase db, String table, String id) async {
  final row = await db
      .customSelect(
        "SELECT COUNT(*) AS total FROM $table "
        "WHERE id = '$id' AND deleted_at IS NULL;",
      )
      .getSingle();
  return row.read<int>('total');
}

Future<int> _outboxCount(
  AppDatabase db,
  String table,
  String idColumn,
  String id,
) async {
  final row = await db
      .customSelect(
        "SELECT COUNT(*) AS total FROM $table WHERE $idColumn = '$id';",
      )
      .getSingle();
  return row.read<int>('total');
}

Future<String?> _syncStatus(
  AppDatabase db,
  String table,
  String id,
) async {
  final row = await db
      .customSelect(
        "SELECT sync_status FROM $table WHERE id = '$id' LIMIT 1;",
      )
      .getSingleOrNull();
  return row?.readNullable<String>('sync_status');
}

void main() {
  late AppDatabase db;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
  });

  tearDown(() async => db.close());

  test('transaction and ledger outbox commit or roll back together', () async {
    final repository = DriftTransactionRepository(
      db,
      outboxQueue: _ledgerQueue(db),
    );
    await db.customStatement('''
      CREATE TRIGGER fail_transaction_pending
      BEFORE UPDATE OF sync_status ON transactions
      BEGIN
        SELECT RAISE(ABORT, 'injected transaction enqueue failure');
      END;
    ''');

    await expectLater(
      repository.saveTransaction(
        transaction: _transaction('tx-fails'),
        categoryKey: null,
      ),
      throwsA(anything),
    );

    expect(await _count(db, 'transactions', 'tx-fails'), 0);
    expect(
      await _outboxCount(
        db,
        'ledger_sync_outbox',
        'transaction_id',
        'tx-fails',
      ),
      0,
    );
    final merchantCount = await db
        .customSelect(
          "SELECT COUNT(*) AS total FROM merchants "
          "WHERE raw_name = 'Atomic Store tx-fails';",
        )
        .getSingle();
    expect(merchantCount.read<int>('total'), 0);

    await db.customStatement('DROP TRIGGER fail_transaction_pending;');
    await repository.saveTransaction(
      transaction: _transaction('tx-succeeds'),
      categoryKey: null,
    );

    expect(await _count(db, 'transactions', 'tx-succeeds'), 1);
    expect(
      await _outboxCount(
        db,
        'ledger_sync_outbox',
        'transaction_id',
        'tx-succeeds',
      ),
      1,
    );
    expect(await _syncStatus(db, 'transactions', 'tx-succeeds'), 'pending');
  });

  test('goal contribution, total, and child outbox are atomic', () async {
    final goal = _goal();
    await DriftGoalRepository(db).save(goal);
    final repository = DriftGoalRepository(
      db,
      outboxQueue: _planningQueue(db),
    );
    final contribution = GoalContributionEntity(
      id: 'contribution-atomic',
      goalId: goal.id,
      amount: 75,
      createdAt: DateTime.utc(2026, 7, 28, 13),
    );
    await db.customStatement('''
      CREATE TRIGGER fail_contribution_pending
      BEFORE UPDATE OF sync_status ON goal_contributions
      BEGIN
        SELECT RAISE(ABORT, 'injected contribution enqueue failure');
      END;
    ''');

    await expectLater(
      repository.addContribution(contribution),
      throwsA(anything),
    );

    expect(await _count(db, 'goal_contributions', contribution.id), 0);
    expect((await repository.getById(goal.id))?.savedAmount, 100);
    expect(
      await _outboxCount(
        db,
        'planning_sync_outbox',
        'entity_id',
        contribution.id,
      ),
      0,
    );

    await db.customStatement('DROP TRIGGER fail_contribution_pending;');
    await repository.addContribution(contribution);

    expect(await _count(db, 'goal_contributions', contribution.id), 1);
    expect((await repository.getById(goal.id))?.savedAmount, 175);
    expect(
      await _outboxCount(
        db,
        'planning_sync_outbox',
        'entity_id',
        contribution.id,
      ),
      1,
    );
    expect(
      await _syncStatus(db, 'goal_contributions', contribution.id),
      'pending',
    );
  });

  test('bill payment, paid counter, and child outbox are atomic', () async {
    final bill = _bill();
    await DriftBillRepository(db).save(bill);
    final repository = DriftBillRepository(
      db,
      outboxQueue: _planningQueue(db),
    );
    final payment = _payment();
    await db.customStatement('''
      CREATE TRIGGER fail_payment_pending
      BEFORE UPDATE OF sync_status ON bill_payments
      BEGIN
        SELECT RAISE(ABORT, 'injected payment enqueue failure');
      END;
    ''');

    await expectLater(
      repository.recordPayment(payment),
      throwsA(anything),
    );

    expect(await _count(db, 'bill_payments', payment.id), 0);
    expect((await repository.getById(bill.id))?.paidCount, 0);
    expect(
      await _outboxCount(
        db,
        'planning_sync_outbox',
        'entity_id',
        payment.id,
      ),
      0,
    );

    await db.customStatement('DROP TRIGGER fail_payment_pending;');
    await repository.recordPayment(payment);

    expect(await _activeCount(db, 'bill_payments', payment.id), 1);
    expect((await repository.getById(bill.id))?.paidCount, 1);
    expect(
      await _outboxCount(
        db,
        'planning_sync_outbox',
        'entity_id',
        payment.id,
      ),
      1,
    );
    expect(await _syncStatus(db, 'bill_payments', payment.id), 'pending');
  });

  test('nested transaction failure rolls back its savepoint only', () async {
    final repository = DriftTransactionRepository(
      db,
      outboxQueue: _ledgerQueue(db),
    );

    await db.transaction(() async {
      await repository.saveTransaction(
        transaction: _transaction('tx-before-savepoint'),
        categoryKey: null,
      );
      await db.customStatement('''
        CREATE TRIGGER fail_nested_pending
        BEFORE UPDATE OF sync_status ON transactions
        BEGIN
          SELECT RAISE(ABORT, 'injected nested enqueue failure');
        END;
      ''');
      try {
        await repository.saveTransaction(
          transaction: _transaction('tx-rolled-back-savepoint'),
          categoryKey: null,
        );
      } catch (_) {
        // The outer transaction deliberately continues after this savepoint.
      }
      await db.customStatement('DROP TRIGGER fail_nested_pending;');
      await repository.saveTransaction(
        transaction: _transaction('tx-after-savepoint'),
        categoryKey: null,
      );
    });

    expect(await _count(db, 'transactions', 'tx-before-savepoint'), 1);
    expect(await _count(db, 'transactions', 'tx-rolled-back-savepoint'), 0);
    expect(await _count(db, 'transactions', 'tx-after-savepoint'), 1);
    expect(await db.count('ledger_sync_outbox'), 2);
  });

  test('transaction deletion and bill cleanup share the outer transaction',
      () async {
    final transactionRepository = DriftTransactionRepository(
      db,
      outboxQueue: _ledgerQueue(db),
    );
    final billRepository = DriftBillRepository(
      db,
      outboxQueue: _planningQueue(db),
    );
    final transaction = _transaction('tx-with-bill-payment');
    final bill = _bill();
    final payment = BillPaymentEntity(
      id: 'linked-payment',
      billId: bill.id,
      amount: 250,
      currency: 'SAR',
      periodStart: DateTime.utc(2026, 8, 1),
      periodEnd: DateTime.utc(2026, 8, 31),
      paidAt: DateTime.utc(2026, 8, 2),
      installmentIndex: 1,
      transactionId: transaction.id,
    );
    await transactionRepository.saveTransaction(
      transaction: transaction,
      categoryKey: null,
    );
    await DriftBillRepository(db).save(bill);
    await billRepository.recordPayment(payment);
    // MALI-052n: simulate the creates already synced, so the deletes below
    // produce real server delete-ops (a fresh INSERT the trigger can catch)
    // rather than coalescing the pending creates away. Keeps this an atomicity
    // test (delete + bill cleanup share the outer transaction) under coalescing.
    await db.customStatement(
      "UPDATE transactions SET server_id = 'srv-tx', sync_status = 'synced' "
      "WHERE id = '${transaction.id}';",
    );
    await db.customStatement(
      "UPDATE bill_payments SET server_id = 'srv-pay', sync_status = 'synced' "
      "WHERE id = '${payment.id}';",
    );
    await db.customStatement('DELETE FROM ledger_sync_outbox;');
    await db.customStatement('DELETE FROM planning_sync_outbox;');
    await db.customStatement('''
      CREATE TRIGGER fail_bill_cleanup_outbox
      BEFORE INSERT ON planning_sync_outbox
      BEGIN
        SELECT RAISE(ABORT, 'injected bill cleanup enqueue failure');
      END;
    ''');

    await expectLater(
      db.transaction(() async {
        await transactionRepository.deleteTransaction(transaction.id);
        await billRepository.deletePaymentForTransaction(transaction.id);
      }),
      throwsA(anything),
    );

    expect(
      (await transactionRepository.getById(transaction.id))?.status,
      TransactionStatus.confirmed,
    );
    expect(await _count(db, 'bill_payments', payment.id), 1);
    expect((await billRepository.getById(bill.id))?.paidCount, 1);
    expect(
      await _outboxCount(
        db,
        'ledger_sync_outbox',
        'transaction_id',
        transaction.id,
      ),
      0,
      reason: 'the delete enqueue rolled back with the aborted transaction',
    );

    await db.customStatement('DROP TRIGGER fail_bill_cleanup_outbox;');
    await db.transaction(() async {
      await transactionRepository.deleteTransaction(transaction.id);
      await billRepository.deletePaymentForTransaction(transaction.id);
    });

    expect(
      (await transactionRepository.getById(transaction.id))?.status,
      TransactionStatus.ignored,
    );
    expect(await _activeCount(db, 'bill_payments', payment.id), 0);
    expect((await billRepository.getById(bill.id))?.paidCount, 0);
    expect(
      await _outboxCount(
        db,
        'ledger_sync_outbox',
        'transaction_id',
        transaction.id,
      ),
      1,
      reason: 'one coalesced delete row (the create was already synced/cleared)',
    );
    expect(
      await _outboxCount(
        db,
        'planning_sync_outbox',
        'entity_id',
        payment.id,
      ),
      1,
    );
  });
}
