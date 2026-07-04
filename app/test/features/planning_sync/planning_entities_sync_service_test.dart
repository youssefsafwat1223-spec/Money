import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_bill_repository.dart';
import 'package:money_companion/data/repositories/drift_budget_repository.dart';
import 'package:money_companion/data/repositories/drift_goal_repository.dart';
import 'package:money_companion/data/repositories/drift_plan_repository.dart';
import 'package:money_companion/domain/entities/bill_entity.dart';
import 'package:money_companion/domain/entities/budget_entity.dart';
import 'package:money_companion/domain/entities/goal_entity.dart';
import 'package:money_companion/domain/entities/plan_entity.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';
import 'package:money_companion/features/planning_sync/services/planning_pull_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_push_service.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';

  @override
  Future<String?> readStoredKey() async => 'test-key';
}

class _FakePlanningRemote implements PlanningRemoteSink, PlanningRemoteSource {
  final rows = <String, Map<String, Map<String, dynamic>>>{};
  final tombstones = <String, List<Map<String, dynamic>>>{};
  int upserts = 0;
  int deletes = 0;

  @override
  Future<List<Map<String, dynamic>>> fetchActiveRows(
    String table, {
    int limit = 200,
  }) async {
    return (rows[table]?.values ?? const <Map<String, dynamic>>[])
        .where((row) => row['deleted_at'] == null)
        .take(limit)
        .map(Map<String, dynamic>.from)
        .toList();
  }

  @override
  Future<List<Map<String, dynamic>>> fetchTombstones(
    String table, {
    int limit = 200,
  }) async {
    return (tombstones[table] ?? const <Map<String, dynamic>>[])
        .take(limit)
        .map(Map<String, dynamic>.from)
        .toList();
  }

  @override
  Future<Map<String, dynamic>?> findByLocalId(
    String table,
    String userId,
    String localId,
  ) async {
    return rows[table]?[localId];
  }

  @override
  Future<void> tombstone(String table, String serverId) async {
    deletes++;
    final match = rows[table]?.values.firstWhere(
          (row) => row['id'] == serverId,
          orElse: () => <String, dynamic>{},
        );
    if (match == null || match.isEmpty) return;
    final deletedAt = DateTime.utc(2026, 7, 6).toIso8601String();
    match['deleted_at'] = deletedAt;
    match['updated_at'] = deletedAt;
    tombstones.putIfAbsent(table, () => []).add(Map.of(match));
  }

  @override
  Future<Map<String, dynamic>> upsert(
    String table,
    Map<String, dynamic> row,
  ) async {
    upserts++;
    final localId = row['local_id'] as String;
    final now = DateTime.utc(2026, 7, 5, 1).toIso8601String();
    final saved = {
      ...row,
      'id': rows[table]?[localId]?['id'] ?? 'server-$table-$localId',
      'updated_at': now,
      'deleted_at': null,
    };
    rows.putIfAbsent(table, () => {})[localId] = saved;
    return {'id': saved['id'], 'updated_at': now};
  }
}

Future<AppDatabase> _openDb() {
  return AppDatabase.open(
    executor: NativeDatabase.memory(),
    keyStore: _MemoryKeyStore(),
  );
}

PlanningOutboxQueue _queue(
  AppDatabase db, {
  required bool enabled,
  String? userId = 'user-1',
}) {
  return PlanningOutboxQueue(
    db: db,
    isSyncEnabled: (_) => enabled,
    getAuthUserId: () async => userId,
  );
}

Future<int> _outboxCount(AppDatabase db) async {
  final row = await db
      .customSelect('SELECT COUNT(*) AS total FROM planning_sync_outbox;')
      .getSingle();
  return row.read<int>('total');
}

BudgetEntity _budget(String id) => BudgetEntity(
      id: id,
      categoryId: BudgetEntity.allExpensesCategoryId,
      amount: 500,
      period: BudgetPeriod.monthly,
      startDate: DateTime.utc(2026, 7, 1),
      isActive: true,
      alert80Sent: false,
      alert100Sent: false,
      showOnHeader: true,
    );

BillEntity _bill(String id) => BillEntity(
      id: id,
      name: 'Netflix',
      amount: 39,
      currency: 'SAR',
      type: BillType.subscription,
      frequency: BillFrequency.monthly,
      nextDueDate: DateTime.utc(2026, 7, 10),
      reminderOn: true,
      isConfirmed: true,
      createdAt: DateTime.utc(2026, 7, 1),
    );

GoalEntity _goal(String id) => GoalEntity(
      id: id,
      name: 'Travel',
      targetAmount: 5000,
      savedAmount: 300,
      vaultSkin: 'classic',
      status: 'active',
      createdAt: DateTime.utc(2026, 7, 1),
    );

PlanEntity _plan(String id) => PlanEntity(
      id: id,
      name: 'Summer',
      budgetAmount: 2000,
      currency: 'SAR',
      startDate: DateTime.utc(2026, 7, 1),
      endDate: DateTime.utc(2026, 7, 31),
      accountIds: const [],
      cardLast4s: const ['1234'],
      status: PlanStatus.active,
      createdAt: DateTime.utc(2026, 7, 1),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('planning entity sync foundations', () {
    late AppDatabase db;

    setUp(() async {
      db = await _openDb();
    });

    tearDown(() async {
      await db.close();
    });

    test('planning flags OFF do not queue writes', () async {
      final queue = _queue(db, enabled: false);
      await DriftBudgetRepository(db, outboxQueue: queue).save(_budget('b1'));
      await DriftBillRepository(db, outboxQueue: queue).save(_bill('s1'));
      await DriftGoalRepository(db, outboxQueue: queue).save(_goal('g1'));
      await DriftPlanRepository(db, outboxQueue: queue).save(_plan('p1'));

      expect(await _outboxCount(db), 0);
    });

    test('guest user does not queue planning writes when flags are ON',
        () async {
      final queue = _queue(db, enabled: true, userId: null);
      await DriftBudgetRepository(db, outboxQueue: queue).save(_budget('b1'));
      await DriftBillRepository(db, outboxQueue: queue).save(_bill('s1'));
      await DriftGoalRepository(db, outboxQueue: queue).save(_goal('g1'));
      await DriftPlanRepository(db, outboxQueue: queue).save(_plan('p1'));

      expect(await _outboxCount(db), 0);
    });

    test('signed-in flag ON queues and pushes create update delete', () async {
      final remote = _FakePlanningRemote();
      final queue = _queue(db, enabled: true);
      final push = PlanningPushService(
        db: db,
        queue: queue,
        isEnabled: (_) => true,
        getAuthUserId: () async => 'user-1',
        remoteSink: remote,
      );

      final budgets = DriftBudgetRepository(db, outboxQueue: queue);
      final bills = DriftBillRepository(db, outboxQueue: queue);
      final goals = DriftGoalRepository(db, outboxQueue: queue);
      final plans = DriftPlanRepository(db, outboxQueue: queue);

      await budgets.save(_budget('b1'));
      await budgets.save(_budget('b1').copyWith(amount: 600));
      await budgets.save(_budget('b-delete'));
      await budgets.delete('b-delete');
      await bills.save(_bill('s1'));
      await goals.save(_goal('g1'));
      await plans.save(_plan('p1'));

      final result = await push.push();

      expect(result.failed, 0);
      expect(result.pushed, greaterThanOrEqualTo(7));
      expect(await _outboxCount(db), 0);
      expect(remote.rows['user_budgets']?['b1']?['amount'], 600);
      expect(remote.rows['user_subscriptions']?['s1']?['name'], 'Netflix');
      expect(remote.rows['user_goals']?['g1']?['saved_amount'], 300);
      expect(remote.rows['user_plans']?['p1']?['name'], 'Summer');
      expect(remote.deletes, 1);
    });

    test(
        'pull imports once, duplicate pull does not duplicate, tombstone hides',
        () async {
      final remote = _FakePlanningRemote();
      remote.rows['user_budgets'] = {
        'remote-budget': {
          'id': 'server-budget',
          'local_id': 'remote-budget',
          'category_id': BudgetEntity.allExpensesCategoryId,
          'amount': 750,
          'period': 'monthly',
          'start_date': DateTime.utc(2026, 7, 1).toIso8601String(),
          'is_active': true,
          'alert_80_sent': false,
          'alert_100_sent': false,
          'show_on_header': true,
          'updated_at': DateTime.utc(2026, 7, 2).toIso8601String(),
          'deleted_at': null,
        },
      };
      final pull = PlanningPullService(
        db: db,
        isEnabled: (_) => true,
        getAuthUserId: () async => 'user-1',
        remoteSource: remote,
      );

      final first = await pull.pull();
      final second = await pull.pull();

      expect(first.imported, 1);
      expect(second.imported, 0);
      final count = await db
          .customSelect(
            "SELECT COUNT(*) AS total FROM budgets WHERE id = 'remote-budget';",
          )
          .getSingle();
      expect(count.read<int>('total'), 1);

      remote.tombstones['user_budgets'] = [
        {
          'id': 'server-budget',
          'local_id': 'remote-budget',
          'deleted_at': DateTime.utc(2026, 7, 3).toIso8601String(),
          'updated_at': DateTime.utc(2026, 7, 3).toIso8601String(),
        }
      ];

      final tombstone = await pull.pull();

      expect(tombstone.tombstoned, 1);
      expect(await DriftBudgetRepository(db).getById('remote-budget'), isNull);
      final deleted = await db
          .customSelect(
            "SELECT deleted_at FROM budgets WHERE id = 'remote-budget';",
          )
          .getSingle();
      expect(deleted.readNullable<String>('deleted_at'), isNotNull);
    });

    test('pull marks pending local planning row as conflict', () async {
      final remote = _FakePlanningRemote();
      await DriftGoalRepository(db).save(_goal('conflict-goal'));
      await db.customStatement(
        "UPDATE goals SET sync_status = 'pending' WHERE id = 'conflict-goal';",
      );
      remote.rows['user_goals'] = {
        'conflict-goal': {
          'id': 'server-conflict-goal',
          'local_id': 'conflict-goal',
          'name': 'Remote',
          'target_amount': 9000,
          'saved_amount': 100,
          'vault_skin': 'classic',
          'status': 'active',
          'created_at': DateTime.utc(2026, 7, 1).toIso8601String(),
          'updated_at': DateTime.utc(2026, 7, 2).toIso8601String(),
          'deleted_at': null,
        }
      };

      final pull = PlanningPullService(
        db: db,
        isEnabled: (_) => true,
        getAuthUserId: () async => 'user-1',
        remoteSource: remote,
      );

      final result = await pull.pull();

      expect(result.conflicts, 1);
      final row = await db
          .customSelect(
            "SELECT name, sync_status FROM goals WHERE id = 'conflict-goal';",
          )
          .getSingle();
      expect(row.read<String>('name'), 'Travel');
      expect(row.readNullable<String>('sync_status'), 'conflict');
    });
  });
}
