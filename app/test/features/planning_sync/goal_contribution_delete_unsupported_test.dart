import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/sync/exact_transport_capability.dart';
import 'package:money_companion/domain/entities/goal_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/planning_sync/services/planning_child_sync_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';

/// A-4 (G12): the server has NO goal-contribution delete/reversal endpoint
/// (only add_goal_contribution), and no local code path enqueues one. If a
/// delete row ever exists it must dead-letter immediately as an observable
/// permanent failure — not be retried 12 times as a transient error.
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
