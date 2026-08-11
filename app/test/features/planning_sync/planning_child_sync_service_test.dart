import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
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

  @override
  Future<Map<String, dynamic>> callRpc(
    String name,
    Map<String, dynamic> params,
  ) async {
    const now = '2026-07-23T10:00:00.000Z';
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
        {int pageSize = 200}) =>
    PlanningChildSyncService(
      db: db,
      queue: queue,
      isEnabled: (_) => true,
      getAuthUserId: () async => 'user-1',
      remote: remote,
      pageSize: pageSize,
    );

Future<void> _seedParents(AppDatabase db) async {
  const now = '2026-07-23T09:00:00.000Z';
  await db.customStatement('''
    INSERT INTO merchants(id,raw_name,normalized_name,first_seen_at,last_seen_at)
    VALUES ('merchant-1','نت','نت','$now','$now');
  ''');
  await db.customStatement('''
    INSERT INTO goals(id,name,target_amount,saved_amount,vault_skin,status,
      created_at,server_id,sync_status)
    VALUES ('goal-1','هدف',100,0,'classic','active','$now','server-goal-1','synced');
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
      amount: 25,
      createdAt: DateTime.utc(2026, 7, 23, 9),
    );
    await db.customStatement('''
      INSERT INTO goal_contributions(id,goal_id,amount,created_at)
      VALUES ('gc-1','goal-1',25,'2026-07-23T09:00:00Z');
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
}
