import 'package:drift/drift.dart';

import '../../domain/entities/goal_entity.dart';
import '../../domain/finance/planning_mutation_guard.dart';
import '../../domain/repositories/goal_repository.dart';
import '../../features/planning_sync/services/planning_outbox_queue.dart';
import '../db/app_database.dart';
import '../db/planning_cutover.dart';
import '../db/sql_value_codec.dart';
import 'drift_repository_support.dart';

class DriftGoalRepository implements GoalRepository {
  DriftGoalRepository(
    this._db, {
    PlanningOutboxQueue? outboxQueue,
    // MALI-026 (B8-2.10 §1): the authoritative planning-mutation boundary. The
    // default resolves to schema-v29 legacy, so every existing construction site
    // and today's production behavior is unchanged; only an injected unresolved
    // coordinator (future v30 P1) makes these writes throw.
    PlanningMutationGuard guard =
        const PlanningMutationGuard(SchemaV29PlanningCutoverCoordinator()),
  })  : _outboxQueue = outboxQueue,
        _guard = guard;

  final AppDatabase _db;
  final PlanningOutboxQueue? _outboxQueue;
  final PlanningMutationGuard _guard;

  @override
  Future<GoalContributionEntity> addContribution(
    GoalContributionEntity contribution,
  ) async {
    _guard.requireMutable();
    return _db.transaction(() async {
      await _db.customStatement('''
      INSERT INTO goal_contributions(id, goal_id, amount, created_at, note)
      VALUES (
        ${sqlString(contribution.id)},
        ${sqlString(contribution.goalId)},
        ${contribution.amount},
        ${sqlString(dateTimeToSql(contribution.createdAt))},
        ${sqlNullableString(contribution.note)}
      );
    ''');

      await _db.customUpdate(
        '''
        UPDATE goals
        SET saved_amount = saved_amount + ?
        WHERE id = ?;
      ''',
        variables: [
          Variable.withReal(contribution.amount),
          Variable.withString(contribution.goalId),
        ],
      );
      // The server RPC atomically inserts the contribution and updates the goal
      // total. Queue the child itself; queuing a parent update here would race the
      // RPC and can double-count across devices.
      await _outboxQueue?.enqueueGoalContribution(
        PlanningSyncOperation.create,
        contribution,
      );
      return contribution;
    });
  }

  @override
  Future<void> delete(String id) async {
    _guard.requireDeletable();
    await _db.transaction(() async {
      final existing = await getById(id);
      final now = dateTimeToSql(DateTime.now().toUtc());
      await _db.customUpdate(
        '''
      UPDATE goals
      SET deleted_at = ?, status = 'archived'
      WHERE id = ?;
      ''',
        variables: [
          Variable.withString(now),
          Variable.withString(id),
        ],
      );
      if (existing != null) {
        await _outboxQueue?.enqueueGoal(
          PlanningSyncOperation.delete,
          existing,
        );
      }
    });
  }

  @override
  Future<int> countAll() async {
    final row = await _db
        .customSelect(
          'SELECT COUNT(*) AS total FROM goals WHERE deleted_at IS NULL;',
        )
        .getSingle();
    return row.read<int>('total');
  }

  @override
  Future<List<GoalEntity>> getAll() async {
    final rows = await _db
        .customSelect(
          'SELECT * FROM goals WHERE deleted_at IS NULL ORDER BY created_at DESC;',
        )
        .get();
    return rows.map(goalFromRow).toList();
  }

  @override
  Future<GoalEntity?> getById(String id) async {
    final row = await _db.customSelect(
      'SELECT * FROM goals WHERE id = ? AND deleted_at IS NULL LIMIT 1;',
      variables: [Variable.withString(id)],
    ).getSingleOrNull();
    return row == null ? null : goalFromRow(row);
  }

  @override
  Future<List<GoalContributionEntity>> getContributions(String goalId) async {
    final rows = await _db.customSelect(
      '''
        SELECT * FROM goal_contributions
        WHERE goal_id = ? AND deleted_at IS NULL
        ORDER BY created_at DESC;
      ''',
      variables: [Variable.withString(goalId)],
    ).get();
    return rows.map(goalContributionFromRow).toList();
  }

  @override
  Future<GoalEntity> save(GoalEntity goal) async {
    _guard.requireMutable();
    return _db.transaction(() async {
      final existing = await getById(goal.id);
      final autoAmount =
          goal.autoSaveAmount == null ? 'NULL' : '${goal.autoSaveAmount}';
      final autoPeriod = sqlNullableString(goal.autoSavePeriod);
      final autoLastRun = sqlNullableString(goal.autoSaveLastRun == null
          ? null
          : dateTimeToSql(goal.autoSaveLastRun!));
      if (existing == null) {
        await _db.customStatement('''
        INSERT INTO goals(
          id, name, account_id, target_amount, saved_amount, deadline, vault_skin, status, created_at,
          last_notified_saved_amount,
          auto_save_amount, auto_save_period, auto_save_last_run
        ) VALUES (
          ${sqlString(goal.id)},
          ${sqlString(goal.name)},
          ${sqlNullableString(goal.accountId)},
          ${goal.targetAmount},
          ${goal.savedAmount},
          ${sqlNullableString(goal.deadline == null ? null : dateTimeToSql(goal.deadline!))},
          ${sqlString(goal.vaultSkin)},
          ${sqlString(goal.status)},
          ${sqlString(dateTimeToSql(goal.createdAt))},
          ${goal.lastNotifiedSavedAmount},
          $autoAmount, $autoPeriod, $autoLastRun
        );
      ''');
        await _outboxQueue?.enqueueGoal(
          PlanningSyncOperation.create,
          goal,
        );
      } else {
        await _db.customStatement('''
        UPDATE goals
        SET name = ${sqlString(goal.name)},
            account_id = ${sqlNullableString(goal.accountId)},
            target_amount = ${goal.targetAmount},
            saved_amount = ${goal.savedAmount},
            deadline = ${sqlNullableString(goal.deadline == null ? null : dateTimeToSql(goal.deadline!))},
            vault_skin = ${sqlString(goal.vaultSkin)},
            status = ${sqlString(goal.status)},
            created_at = ${sqlString(dateTimeToSql(goal.createdAt))},
            last_notified_saved_amount = ${goal.lastNotifiedSavedAmount},
            auto_save_amount = $autoAmount,
            auto_save_period = $autoPeriod,
            auto_save_last_run = $autoLastRun
        WHERE id = ${sqlString(goal.id)};
      ''');
        await _outboxQueue?.enqueueGoal(
          PlanningSyncOperation.update,
          goal,
        );
      }
      return goal;
    });
  }
}
