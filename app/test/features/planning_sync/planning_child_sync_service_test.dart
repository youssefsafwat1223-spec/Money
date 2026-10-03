import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';
import 'package:money_companion/data/sync/exact_transport_capability.dart';
import 'package:money_companion/data/sync/sync_cursor.dart';
import 'package:money_companion/domain/entities/bill_entity.dart';
import 'package:money_companion/domain/entities/goal_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/planning_sync/services/planning_child_sync_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

class _FakeChildRemote implements PlanningChildRemote {
  final rows = <String, List<Map<String, dynamic>>>{};

  /// Runs while a push is on the wire (the item is in flight).
  Future<void> Function()? duringPush;

  @override
  Future<Map<String, dynamic>> callRpc(
    String name,
    Map<String, dynamic> params,
  ) async {
    const now = '2026-07-23T10:00:00.000Z';
    await duringPush?.call();
    if (name == 'add_goal_contribution') {
      final contribution = <String, dynamic>{
        'id': 'server-gc-${params['p_local_id']}',
        'local_id': params['p_local_id'],
        'goal_id': params['p_goal_id'],
        'amount': params['p_amount'],
        'created_at': params['p_created_at'],
        'note': params['p_note'],
        'updated_at': now,
        'deleted_at': null,
      };
      rows.putIfAbsent('user_goal_contributions', () => []).add(contribution);
      return {
        'contribution': contribution,
        'goal': {
          'id': params['p_goal_id'],
          'saved_amount': params['p_amount'],
          'updated_at': now,
        },
      };
    }
    if (name == 'record_bill_payment') {
      final payment = <String, dynamic>{
        'id': 'server-bp-${params['p_local_id']}',
        'local_id': params['p_local_id'],
        'subscription_id': params['p_subscription_id'],
        'transaction_id': params['p_transaction_id'],
        'amount': params['p_amount'],
        'amount_text': '${params['p_amount']}',
        'currency': params['p_currency'],
        'period_start': params['p_period_start'],
        'period_end': params['p_period_end'],
        'paid_at': params['p_paid_at'],
        'installment_index': params['p_installment_index'],
        'note': params['p_note'],
        'created_at': now,
        'updated_at': now,
        'deleted_at': null,
      };
      rows.putIfAbsent('user_bill_payments', () => []).add(payment);
      return {
        'payment': payment,
        'subscription': {
          'id': params['p_subscription_id'],
          'paid_count': 1,
          'manual_paid_amount': 0,
          'currency': params['p_currency'],
          'updated_at': now,
        },
      };
    }
    throw UnsupportedError(name);
  }

  @override
  Future<List<Map<String, dynamic>>> fetchRows(
    String table, {
    required SyncCursor after,
    int limit = 200,
  }) async {
    final ordered =
        (rows[table] ?? const []).map(Map<String, dynamic>.from).toList()
          ..sort((left, right) {
            final timestamp = normalizeCursorTimestamp(left['updated_at'])
                .compareTo(normalizeCursorTimestamp(right['updated_at']));
            if (timestamp != 0) return timestamp;
            return (left['id'] as String).compareTo(right['id'] as String);
          });
    return ordered
        .where((row) {
          if (after.id.isEmpty) return true;
          final timestamp = normalizeCursorTimestamp(row['updated_at']);
          final comparison = timestamp.compareTo(after.updatedAt);
          return comparison > 0 ||
              (comparison == 0 &&
                  (row['id'] as String).compareTo(after.id) > 0);
        })
        .take(limit)
        .toList();
  }

  @override
  Future<Map<String, dynamic>?> findPlanLink({
    required String userId,
    required String planId,
    required String transactionId,
  }) async {
    for (final row in rows['user_plan_transaction_links'] ??
        const <Map<String, dynamic>>[]) {
      if (row['plan_id'] == planId && row['transaction_id'] == transactionId) {
        return row;
      }
    }
    return null;
  }

  @override
  Future<void> tombstonePlanLink(String serverId) async {
    final row = (rows['user_plan_transaction_links'] ?? const [])
        .firstWhere((item) => item['id'] == serverId);
    row['deleted_at'] = '2026-07-23T11:00:00.000Z';
  }

  @override
  Future<Map<String, dynamic>> upsertPlanLink(
    Map<String, dynamic> row,
  ) async {
    await duringPush?.call();
    final existing = await findPlanLink(
      userId: row['user_id'] as String,
      planId: row['plan_id'] as String,
      transactionId: row['transaction_id'] as String,
    );
    if (existing != null) return existing;
    final saved = <String, dynamic>{
      ...row,
      'id': 'server-link-1',
      'updated_at': '2026-07-23T10:00:00.000Z',
      'deleted_at': null,
    };
    rows.putIfAbsent('user_plan_transaction_links', () => []).add(saved);
    return saved;
  }
}

/// Succeeds on the wire but returns a goal body the apply step cannot decode.
class _FailingGoalRemote extends _FakeChildRemote {
  @override
  Future<Map<String, dynamic>> callRpc(
    String name,
    Map<String, dynamic> params,
  ) async =>
      {
        'contribution': {
          'id': 'server-gc-${params['p_local_id']}',
          'updated_at': '2026-07-23T10:00:00.000Z',
          'deleted_at': null,
        },
        'goal': {'id': params['p_goal_id']},
      };
}

Future<AppDatabase> _openDb() => AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );

PlanningOutboxQueue _queue(AppDatabase db) => PlanningOutboxQueue(
      db: db,
      isSyncEnabled: (_) => true,
      getAuthUserId: () async => 'user-1',
    );

PlanningChildSyncService _service(
        AppDatabase db, PlanningOutboxQueue queue, _FakeChildRemote remote,
        {int pageSize = 200, bool pull = true}) =>
    PlanningChildSyncService(
      db: db,
      queue: queue,
      isEnabled: (_) => true,
      isPullEnabled: (_) => pull,
      getAuthUserId: () async => 'user-1',
      remote: remote,
      pageSize: pageSize,
      pullCapability: () => ExactTransportCapability.verifiedExact,
    
      // C-3: covers pull MECHANICS; consent is asserted in
      // financial_pull_consent_test.dart.
      mayEgress: () async => true,
    );

Future<void> _seedParents(AppDatabase db) async {
  const now = '2026-07-23T09:00:00.000Z';
  await db.customStatement('''
    INSERT INTO merchants(id,raw_name,normalized_name,first_seen_at,last_seen_at)
    VALUES ('merchant-1','نت','نت','$now','$now');
  ''');
  await db.customStatement('''
    INSERT INTO goals(id,name,target_amount,saved_amount,currency,
      target_amount_minor,saved_amount_minor,last_notified_saved_amount_minor,
      vault_skin,status,created_at,server_id,sync_status)
    VALUES ('goal-1','هدف',100,0,'EGP',10000,0,0,'classic','active',
      '$now','server-goal-1','synced');
  ''');
  await db.customStatement('''
    INSERT INTO subscriptions(id,merchant_id,amount,period,next_due_date,
      is_confirmed,reminder_on,name,type,currency,frequency,created_at,status,
      server_id,sync_status)
      VALUES ('bill-1','merchant-1',10,'monthly','$now',1,1,'نت','subscription','EGP',
      'monthly','$now','active','server-bill-1','synced');
  ''');
  await db.customStatement('''
    INSERT INTO plans(id,name,budget_amount,currency,start_date,end_date,
      account_ids,card_last4s,status,created_at,server_id,sync_status)
    VALUES ('plan-1','سفر',1000,'EGP','$now','2026-08-01T00:00:00Z','','',
      'active','$now','server-plan-1','synced');
  ''');
  await db.customStatement('''
    INSERT INTO transactions(id,amount,currency,type,source,occurred_at,
      raw_message,parse_confidence,status,created_at,updated_at,server_id,
      sync_status)
    VALUES ('tx-1',10,'EGP','payment','manual','$now','',1,'confirmed','$now',
      '$now','server-tx-1','synced');
  ''');
  await backfillNonPlanningMoneyV30(db);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bill-payment pull selects canonical amount text', () {
    expect(
      planningChildBillPaymentSelect,
      contains('amount_text:amount::text'),
    );
  });

  test('goal contribution, bill payment and plan link drain via child worker',
      () async {
    final db = await _openDb();
    addTearDown(db.close);
    await _seedParents(db);
    final queue = _queue(db);
    final remote = _FakeChildRemote();

    final contribution = GoalContributionEntity(
      id: 'gc-1',
      goalId: 'goal-1',
      amountMoney: Money.parse('25', 'EGP'),
      createdAt: DateTime.utc(2026, 7, 23, 9),
    );
    await db.customStatement('''
      INSERT INTO goal_contributions(id,goal_id,amount,amount_minor,created_at)
      VALUES ('gc-1','goal-1',25,2500,'2026-07-23T09:00:00Z');
    ''');
    await queue.enqueueGoalContribution(
      PlanningSyncOperation.create,
      contribution,
    );

    final payment = BillPaymentEntity(
      id: 'bp-1',
      billId: 'bill-1',
      amountMoney: Money.fromLegacyReal(10, 'EGP'),
      currency: 'EGP',
      periodStart: DateTime.utc(2026, 7, 1),
      periodEnd: DateTime.utc(2026, 7, 31),
      paidAt: DateTime.utc(2026, 7, 23),
      transactionId: 'tx-1',
    );
    await db.customStatement('''
      INSERT INTO bill_payments(id,bill_id,amount,currency,period_start,
        period_end,paid_at,transaction_id)
      VALUES ('bp-1','bill-1',10,'EGP','2026-07-01','2026-07-31',
        '2026-07-23','tx-1');
    ''');
    await backfillNonPlanningMoneyV30(db);
    await queue.enqueueBillPayment(PlanningSyncOperation.create, payment);

    await db.customStatement('''
      INSERT INTO plan_transaction_links(plan_id,transaction_id,created_at)
      VALUES ('plan-1','tx-1','2026-07-23T09:00:00Z');
    ''');
    await queue.enqueuePlanLink(
      PlanningSyncOperation.create,
      planId: 'plan-1',
      transactionId: 'tx-1',
      createdAt: DateTime.utc(2026, 7, 23, 9),
    );

    await _service(db, queue, remote).sync();

    final pending = await db
        .customSelect('SELECT COUNT(*) AS n FROM planning_sync_outbox;')
        .getSingle();
    expect(pending.read<int>('n'), 0);
    expect(remote.rows['user_goal_contributions'], hasLength(1));
    expect(remote.rows['user_bill_payments'], hasLength(1));
    expect(remote.rows['user_plan_transaction_links'], hasLength(1));
    final goal = await db
        .customSelect("SELECT saved_amount FROM goals WHERE id='goal-1';")
        .getSingle();
    expect(goal.read<double>('saved_amount'), 25);
  });

  test('second device pulls each child once without duplicates', () async {
    final remote = _FakeChildRemote()
      ..rows['user_goal_contributions'] = [
        {
          'id': 'server-gc-1',
          'local_id': 'gc-1',
          'goal_id': 'server-goal-1',
          'amount': 25,
          'amount_text': '25',
          'created_at': '2026-07-23T09:00:00Z',
          'updated_at': '2026-07-23T10:00:00Z',
          'deleted_at': null,
          'note': null,
        }
      ]
      ..rows['user_bill_payments'] = [
        {
          'id': 'server-bp-1',
          'local_id': 'bp-1',
          'subscription_id': 'server-bill-1',
          'transaction_id': 'server-tx-1',
          'amount': 10,
          'amount_text': '10',
          'currency': 'EGP',
          'period_start': '2026-07-01',
          'period_end': '2026-07-31',
          'paid_at': '2026-07-23',
          'installment_index': null,
          'note': null,
          'updated_at': '2026-07-23T10:00:00Z',
          'deleted_at': null,
        }
      ]
      ..rows['user_plan_transaction_links'] = [
        {
          'id': 'server-link-1',
          'plan_id': 'server-plan-1',
          'transaction_id': 'server-tx-1',
          'created_at': '2026-07-23T09:00:00Z',
          'updated_at': '2026-07-23T10:00:00Z',
          'deleted_at': null,
        }
      ];
    final db = await _openDb();
    addTearDown(db.close);
    await _seedParents(db);
    final service = _service(db, _queue(db), remote);
    await service.sync();
    await service.sync();

    for (final table in [
      'goal_contributions',
      'bill_payments',
      'plan_transaction_links',
    ]) {
      final count = await db
          .customSelect('SELECT COUNT(*) AS n FROM $table;')
          .getSingle();
      expect(count.read<int>('n'), 1, reason: table);
    }
  });

  test('child pull keyset-paginates equal-timestamp contribution rows',
      () async {
    final remote = _FakeChildRemote()
      ..rows['user_goal_contributions'] = List.generate(
        3,
        (index) => {
          'id': 'server-gc-$index',
          'local_id': 'gc-$index',
          'goal_id': 'server-goal-1',
          'amount': 10 + index,
          'amount_text': '${10 + index}',
          'created_at': '2026-07-23T09:00:00.000Z',
          'updated_at': '2026-07-23T10:00:00.000Z',
          'deleted_at': null,
          'note': null,
        },
      );
    final db = await _openDb();
    addTearDown(db.close);
    await _seedParents(db);

    await _service(db, _queue(db), remote, pageSize: 2).sync();

    expect(await db.count('goal_contributions'), 3);
    expect(
      (await readSyncCursor(db, 'planning_child_goal_contributions')).id,
      'server-gc-2',
    );
  });

  // ---- B11 (sync-plan T7 for children): ACK is op_seq-guarded -----------------
  test(
      'T7 bill payment: a delete made while the create is in flight keeps the row pending (not synced, not resurrected)',
      () async {
    final db = await _openDb();
    addTearDown(db.close);
    await _seedParents(db);
    final queue = _queue(db);
    final remote = _FakeChildRemote();
    final payment = BillPaymentEntity(
      id: 'bp-1',
      billId: 'bill-1',
      amountMoney: Money.fromLegacyReal(10, 'EGP'),
      currency: 'EGP',
      periodStart: DateTime.utc(2026, 7, 1),
      periodEnd: DateTime.utc(2026, 7, 31),
      paidAt: DateTime.utc(2026, 7, 23),
      transactionId: 'tx-1',
    );
    await db.customStatement('''
      INSERT INTO bill_payments(id,bill_id,amount,currency,period_start,
        period_end,paid_at,transaction_id)
      VALUES ('bp-1','bill-1',10,'EGP','2026-07-01','2026-07-31',
        '2026-07-23','tx-1');
    ''');
    await backfillNonPlanningMoneyV30(db);
    await queue.enqueueBillPayment(PlanningSyncOperation.create, payment);

    remote.duringPush = () async {
      remote.duringPush = null;
      await db.customStatement(
          "UPDATE bill_payments SET deleted_at = '2026-07-23T10:00:05Z' WHERE id = 'bp-1';");
      await queue.enqueueBillPayment(PlanningSyncOperation.delete, payment);
    };
    await _service(db, queue, remote, pull: false).sync();

    final row = await db
        .customSelect(
            "SELECT sync_status, server_id, deleted_at FROM bill_payments WHERE id = 'bp-1';")
        .getSingle();
    expect(row.read<String>('sync_status'), 'pending',
        reason: 'a newer op exists: never marked synced');
    expect(row.readNullable<String>('deleted_at'), isNotNull,
        reason: 'the local delete is not overwritten by the in-flight create ACK');
    expect(row.read<String>('server_id'), 'server-bp-bp-1',
        reason: 'the server identity is still attached');
    final op = await db
        .customSelect(
            "SELECT operation, op_seq, in_flight_seq FROM planning_sync_outbox WHERE entity_id = 'bp-1';")
        .getSingle();
    expect(op.read<String>('operation'), 'delete');
    expect(op.read<int>('op_seq'), 2);
    expect(op.readNullable<int>('in_flight_seq'), isNull);
  });

  test(
      'T7 plan link: an unlink made while the link create is in flight keeps the link pending',
      () async {
    final db = await _openDb();
    addTearDown(db.close);
    await _seedParents(db);
    final queue = _queue(db);
    final remote = _FakeChildRemote();
    await db.customStatement('''
      INSERT INTO plan_transaction_links(plan_id,transaction_id,created_at)
      VALUES ('plan-1','tx-1','2026-07-23T09:00:00Z');
    ''');
    await queue.enqueuePlanLink(
      PlanningSyncOperation.create,
      planId: 'plan-1',
      transactionId: 'tx-1',
      createdAt: DateTime.utc(2026, 7, 23, 9),
    );
    remote.duringPush = () async {
      remote.duringPush = null;
      await db.customStatement(
          "UPDATE plan_transaction_links SET deleted_at = '2026-07-23T10:00:05Z';");
      await queue.enqueuePlanLink(
        PlanningSyncOperation.delete,
        planId: 'plan-1',
        transactionId: 'tx-1',
        createdAt: DateTime.utc(2026, 7, 23, 10),
      );
    };
    await _service(db, queue, remote, pull: false).sync();

    final row = await db
        .customSelect(
            'SELECT sync_status, server_id, deleted_at FROM plan_transaction_links;')
        .getSingle();
    expect(row.read<String>('sync_status'), 'pending');
    expect(row.readNullable<String>('deleted_at'), isNotNull);
    expect(row.read<String>('server_id'), 'server-link-1');
    final ops = await db
        .customSelect('SELECT operation FROM planning_sync_outbox;')
        .get();
    expect(ops.single.read<String>('operation'), 'delete');
  });

  test('B11: ACK + synced mark are one transaction (a failing apply rolls the ACK back)',
      () async {
    final db = await _openDb();
    addTearDown(db.close);
    await _seedParents(db);
    final queue = _queue(db);
    await db.customStatement('''
      INSERT INTO goal_contributions(id,goal_id,amount,amount_minor,created_at)
      VALUES ('gc-1','goal-1',25,2500,'2026-07-23T09:00:00Z');
    ''');
    await queue.enqueueGoalContribution(
      PlanningSyncOperation.create,
      GoalContributionEntity(
        id: 'gc-1',
        goalId: 'goal-1',
        amountMoney: Money.parse('25', 'EGP'),
        createdAt: DateTime.utc(2026, 7, 23, 9),
      ),
    );
    // A goal response the canonical path cannot decode (no currency) throws
    // after the RPC succeeded.
    final failing = _FailingGoalRemote();
    await _service(db, queue, failing).sync();

    expect(
        (await db.customSelect('SELECT sync_status FROM goal_contributions;').getSingle())
            .readNullable<String>('sync_status'),
        isNot('synced'),
        reason: 'no half-applied ACK');
    expect(await db.count('planning_sync_outbox'), 1,
        reason: 'the op survives for an idempotent retry');
  });
}
