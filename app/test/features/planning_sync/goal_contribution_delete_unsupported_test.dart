import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/sync/exact_transport_capability.dart';
import 'package:money_companion/domain/entities/goal_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/planning_sync/services/planning_child_sync_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';

/// A-4 (G12), narrowed by D1: when the delete endpoint (0116) cannot be used -
/// here no epoch source is wired, so the push cannot prove the replica's epoch -
/// a contribution delete must still dead-letter immediately as an observable
/// permanent failure, not be retried 12 times as a transient error. The endpoint
/// path itself is covered in goal_contribution_delete_test.dart.
class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

class _NoRemote implements PlanningChildRemote {
  @override
  dynamic noSuchMethod(Invocation i) => throw StateError('server must not be called');
}

void main() {
  test('a goal-contribution delete dead-letters at once as unsupported',
      () async {
    final db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    addTearDown(db.close);
    final queue = PlanningOutboxQueue(
      db: db,
      isSyncEnabled: (_) => true,
      getAuthUserId: () async => 'user-1',
    );
    await db.customStatement('''
      INSERT INTO goals(id,name,target_amount,saved_amount,vault_skin,status,
        created_at,server_id,sync_status)
      VALUES ('goal-1','g',100,25,'classic','active','2026-07-23T09:00:00.000Z',
        'srv-goal-1','synced');
    ''');
    await db.customStatement('''
      INSERT INTO goal_contributions(id,goal_id,amount,created_at,server_id,
        sync_status,deleted_at)
      VALUES ('gc-1','goal-1',25,'2026-07-23T09:00:00.000Z','srv-gc-1','pending',
        '2026-07-23T09:00:00.000Z');
    ''');
    await queue.enqueueGoalContribution(
      PlanningSyncOperation.delete,
      GoalContributionEntity(
        id: 'gc-1',
        goalId: 'goal-1',
        amountMoney: Money.parse('25', 'EGP'),
        createdAt: DateTime.utc(2026, 7, 23, 9),
      ),
    );

    await PlanningChildSyncService(
      db: db,
      queue: queue,
      isEnabled: (_) => true,
      isPullEnabled: (_) => false,
      getAuthUserId: () async => 'user-1',
      remote: _NoRemote(),
      pullCapability: () => ExactTransportCapability.verifiedExact,
      mayEgress: () async => true,
    ).sync();

    final row = (await db
            .customSelect("SELECT * FROM planning_sync_outbox "
                "WHERE entity_type = 'goal_contribution';")
            .getSingle())
        .data;
    expect(row['status'], 'dead_letter');
    expect(row['failure_class'], 'permanentValidation');
    expect(row['last_error'].toString(), contains('unsupported_operation'));
    expect(row['attempt_count'], 0, reason: 'never retried');
  });
}
