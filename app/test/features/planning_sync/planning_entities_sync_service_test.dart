import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_bill_repository.dart';
import 'package:money_companion/data/repositories/drift_budget_repository.dart';
import 'package:money_companion/data/repositories/drift_goal_repository.dart';
import 'package:money_companion/data/repositories/drift_plan_repository.dart';
import 'package:money_companion/data/sync/sync_cursor.dart';
import 'package:money_companion/domain/entities/bill_entity.dart';
import 'package:money_companion/domain/entities/budget_entity.dart';
import 'package:money_companion/domain/entities/goal_entity.dart';
import 'package:money_companion/domain/entities/plan_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
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
  Future<List<Map<String, dynamic>>> fetchRows(
    String table, {
    required SyncCursor after,
    int limit = 200,
  }) async {
    final byId = <String, Map<String, dynamic>>{};
    for (final row in <Map<String, dynamic>>[
      ...?rows[table]?.values,
      ...?tombstones[table],
    ]) {
      byId[row['id'] as String] = row;
    }
    final ordered = byId.values.map(Map<String, dynamic>.from).toList()
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
        .map(_projectTextAliases)
        .take(limit)
        .toList();
  }

  // MALI-026 (B8-3 §9): mirror the server's `amount::text` projection — the exact
  // pull reads `<col>_text` decimal strings. This lets a canonical-pushed row
  // round-trip through pull exactly, just as PostgREST would return it.
  static const _moneyTextColumns = [
    'amount',
    'last_notified_spent_amount',
    'target_amount',
    'saved_amount',
    'last_notified_saved_amount',
    'auto_save_amount',
    'budget_amount',
    'manual_paid_amount',
    'total_purchase_amount',
  ];

  Map<String, dynamic> _projectTextAliases(Map<String, dynamic> row) {
    final out = Map<String, dynamic>.from(row);
    for (final col in _moneyTextColumns) {
      if (out.containsKey(col)) {
        out.putIfAbsent('${col}_text', () => out[col]?.toString());
      }
    }
    return out;
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

  @override
  Future<String?> fetchServerUpdatedAt(String table, String serverId) async {
    for (final row in rows[table]?.values ?? const <Map<String, dynamic>>[]) {
      if (row['id'] == serverId) return row['updated_at'] as String?;
    }
    return null;
  }

  @override
  Future<Map<String, dynamic>> updateByServerId(
    String table,
    String serverId,
    Map<String, dynamic> row,
  ) {
    // Keyed by (user_id, local_id) in the fake store — upsert is equivalent.
    return upsert(table, row);
  }

  @override
  Future<Map<String, dynamic>?> casUpdateByServerId(
    String table,
    String serverId,
    int expectedRevision,
    Map<String, dynamic> row,
  ) {
    throw UnimplementedError('CAS is exercised by the dedicated CAS test');
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
      currency: 'SAR',
      amountMoney: Money.parse('500', 'SAR'),
      period: BudgetPeriod.monthly,
      startDate: DateTime.utc(2026, 7, 1),
      isActive: true,
      lastNotifiedSpentMoney: Money(0, 'SAR'),
      lastNotifiedPeriodStart: DateTime.utc(2000, 1, 1),
      showOnHeader: true,
    );

BillEntity _bill(String id) => BillEntity(
      id: id,
      name: 'Netflix',
      amountMoney: Money.fromLegacyReal(39, 'SAR'),
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
      currency: 'SAR',
      targetMoney: Money.parse('5000', 'SAR'),
      savedMoney: Money.parse('300', 'SAR'),
      lastNotifiedSavedMoney: Money(0, 'SAR'),
      vaultSkin: 'classic',
      status: 'active',
      createdAt: DateTime.utc(2026, 7, 1),
    );

PlanEntity _plan(String id) => PlanEntity(
      id: id,
      name: 'Summer',
      budgetAmountMoney: Money.fromLegacyReal(2000, 'SAR'),
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
      await budgets.save(
        _budget('b1').copyWith(amountMoney: Money.parse('600', 'SAR')),
      );
      await budgets.save(_budget('b-delete'));
      await budgets.delete('b-delete');
      await bills.save(_bill('s1'));
      await goals.save(_goal('g1'));
      await plans.save(_plan('p1'));

      final result = await push.push();

      expect(result.failed, 0);
      // MALI-052n coalescing: b1's create+update fold into one create carrying
      // the latest amount; b-delete's create+delete (both offline, never synced)
      // drop entirely (no server round-trip). So exactly 4 pushes: b1, s1, g1, p1.
      expect(result.pushed, 4);
      expect(await _outboxCount(db), 0);
      expect(remote.rows['user_budgets']?['b1']?['amount'], 600);
      expect(remote.rows['user_subscriptions']?['s1']?['name'], 'Netflix');
      expect(remote.rows['user_goals']?['g1']?['saved_amount'], 300);
      expect(remote.rows['user_plans']?['p1']?['name'], 'Summer');
      expect(remote.deletes, 0,
          reason: 'b-delete was created+deleted offline → coalesced away');
    });

    test(
        'pull imports once, duplicate pull does not duplicate, tombstone hides',
        () async {
      final remote = _FakePlanningRemote();
      remote.rows['user_budgets'] = {
        'remote-budget': {
          'id': 'server-budget',
          'local_id': 'remote-budget',
          // The server stores the portable key, while Drift uses a synthetic
          // local FK id for the all-expenses budget.
          'category_id': BudgetEntity.allExpensesCategoryKey,
          'currency': 'SAR',
          'amount': 750,
          'period': 'monthly',
          'start_date': DateTime.utc(2026, 7, 1).toIso8601String(),
          'is_active': true,
          'last_notified_spent_amount': 0,
          'last_notified_period_start': '2000-01-01T00:00:00Z',
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
      final importedCategory = await db
          .customSelect(
            "SELECT category_id FROM budgets WHERE id = 'remote-budget';",
          )
          .getSingle();
      expect(
        importedCategory.read<String>('category_id'),
        BudgetEntity.allExpensesCategoryId,
      );

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

    test('parent pull paginates each planning entity with its own cursor',
        () async {
      final remote = _FakePlanningRemote();
      remote.rows['user_budgets'] = {
        for (var index = 0; index < 3; index++)
          'budget-$index': {
            'id': 'server-budget-$index',
            'local_id': 'budget-$index',
            'category_id': BudgetEntity.allExpensesCategoryKey,
            'currency': 'SAR',
            'amount': 100 + index,
            'last_notified_spent_amount': 0,
            'period': 'monthly',
            'start_date': '2026-07-01T00:00:00.000Z',
            'is_active': true,
            'updated_at': '2026-07-10T00:00:00.000Z',
            'deleted_at': null,
          },
      };

      final result = await PlanningPullService(
        db: db,
        isEnabled: (entity) => entity == PlanningOutboxQueue.budgetsEntityType,
        getAuthUserId: () async => 'user-1',
        remoteSource: remote,
        pageSize: 2,
      ).pull();

      expect(result.imported, 3);
      expect(await db.count('budgets'), 3);
      expect(
        (await readSyncCursor(db, 'planning_budget')).id,
        'server-budget-2',
      );
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
          'currency': 'SAR',
          'target_amount': 9000,
          'saved_amount': 100,
          'last_notified_saved_amount': 0,
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

    test(
        'push conflicts WITHOUT clobbering when the server moved past the base '
        '(MALI-022)', () async {
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

      // Create + push → synced; base token captured.
      await budgets.save(_budget('b1'));
      await push.push();

      // Another device moves the server row past our base.
      remote.rows['user_budgets']!['b1']!['updated_at'] =
          DateTime.utc(2030, 1, 1).toIso8601String();
      remote.rows['user_budgets']!['b1']!['amount'] = 999;

      // Local edit against the OLD base, then push.
      await budgets.save(
        _budget('b1').copyWith(amountMoney: Money.parse('123', 'SAR')),
      );
      final result = await push.push();

      expect(result.conflicts, 1);
      expect(result.pushed, 0);
      // Remote edit NOT clobbered.
      expect(remote.rows['user_budgets']!['b1']!['amount'], 999);
      // Local edit preserved and flagged for resolution.
      final local = await db
          .customSelect(
              "SELECT amount, sync_status FROM budgets WHERE id='b1';")
          .getSingle();
      expect(local.read<double>('amount'), 123);
      expect(local.readNullable<String>('sync_status'), 'conflict');
    });

    test(
        'pull does NOT conflict a pending edit when the server is unchanged '
        '(MALI-022 false-positive fix)', () async {
      final remote = _FakePlanningRemote();
      final queue = _queue(db, enabled: true);
      final push = PlanningPushService(
        db: db,
        queue: queue,
        isEnabled: (_) => true,
        getAuthUserId: () async => 'user-1',
        remoteSink: remote,
      );
      final goals = DriftGoalRepository(db, outboxQueue: queue);
      await goals.save(_goal('g1'));
      await push.push(); // synced; base == server updated_at

      // Local edit → pending; the server row is NOT touched.
      await goals.save(
        _goal('g1').copyWith(savedMoney: Money.parse('777', 'SAR')),
      );
      // §9: the exact pull reads the server row currency; a canonical server row
      // carries it (0077). The legacy push fake omits it, so supply it here.
      remote.rows['user_goals']!['g1']!['currency'] = 'SAR';

      final pull = PlanningPullService(
        db: db,
        isEnabled: (_) => true,
        getAuthUserId: () async => 'user-1',
        remoteSource: remote,
      );
      final result = await pull.pull();

      expect(result.conflicts, 0);
      final row = await db
          .customSelect(
              "SELECT sync_status, saved_amount FROM goals WHERE id='g1';")
          .getSingle();
      expect(row.readNullable<String>('sync_status'), 'pending');
      expect(row.read<double>('saved_amount'), 777);
    });

    test(
        'pull conflicts a pending edit only when the server actually moved '
        '(MALI-022)', () async {
      final remote = _FakePlanningRemote();
      final queue = _queue(db, enabled: true);
      final push = PlanningPushService(
        db: db,
        queue: queue,
        isEnabled: (_) => true,
        getAuthUserId: () async => 'user-1',
        remoteSink: remote,
      );
      final goals = DriftGoalRepository(db, outboxQueue: queue);
      await goals.save(_goal('g1'));
      await push.push();

      await goals.save(
        _goal('g1').copyWith(savedMoney: Money.parse('777', 'SAR')),
      );
      // Server moves past our base.
      remote.rows['user_goals']!['g1']!['updated_at'] =
          DateTime.utc(2030, 1, 1).toIso8601String();
      remote.rows['user_goals']!['g1']!['currency'] = 'SAR';

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
              "SELECT sync_status, saved_amount FROM goals WHERE id='g1';")
          .getSingle();
      expect(row.readNullable<String>('sync_status'), 'conflict');
      expect(row.read<double>('saved_amount'), 777); // local edit not clobbered
    });
  });
}
