import 'package:drift/drift.dart';

import '../../domain/entities/goal_entity.dart';
import '../../domain/repositories/goal_repository.dart';
import '../db/app_database.dart';
import '../db/sql_value_codec.dart';
import 'drift_repository_support.dart';

class DriftGoalRepository implements GoalRepository {
  DriftGoalRepository(this._db);

  final AppDatabase _db;

  @override
  Future<GoalContributionEntity> addContribution(
    GoalContributionEntity contribution,
  ) async {
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
    return contribution;
  }

  @override
  Future<void> delete(String id) async {
    await _db.customUpdate(
      'DELETE FROM goals WHERE id = ?;',
      variables: [Variable.withString(id)],
    );
  }

  @override
  Future<int> countAll() async {
    final row = await _db
        .customSelect(
          'SELECT COUNT(*) AS total FROM goals;',
        )
        .getSingle();
    return row.read<int>('total');
  }

  @override
  Future<List<GoalEntity>> getAll() async {
    final rows = await _db
        .customSelect(
          'SELECT * FROM goals ORDER BY created_at DESC;',
        )
        .get();
    return rows.map(goalFromRow).toList();
  }

  @override
  Future<GoalEntity?> getById(String id) async {
    final row = await _db.customSelect(
      'SELECT * FROM goals WHERE id = ? LIMIT 1;',
      variables: [Variable.withString(id)],
    ).getSingleOrNull();
    return row == null ? null : goalFromRow(row);
  }

  @override
  Future<List<GoalContributionEntity>> getContributions(String goalId) async {
    final rows = await _db.customSelect(
      '''
        SELECT * FROM goal_contributions
        WHERE goal_id = ?
        ORDER BY created_at DESC;
      ''',
      variables: [Variable.withString(goalId)],
    ).get();
    return rows.map(goalContributionFromRow).toList();
  }

  @override
  Future<GoalEntity> save(GoalEntity goal) async {
    final existing = await getById(goal.id);
    final autoAmount =
        goal.autoSaveAmount == null ? 'NULL' : '${goal.autoSaveAmount}';
    final autoPeriod = sqlNullableString(goal.autoSavePeriod);
    final autoLastRun = sqlNullableString(
        goal.autoSaveLastRun == null ? null : dateTimeToSql(goal.autoSaveLastRun!));
    if (existing == null) {
      await _db.customStatement('''
        INSERT INTO goals(
          id, name, account_id, target_amount, saved_amount, deadline, vault_skin, status, created_at,
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
          $autoAmount, $autoPeriod, $autoLastRun
        );
      ''');
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
            auto_save_amount = $autoAmount,
            auto_save_period = $autoPeriod,
            auto_save_last_run = $autoLastRun
        WHERE id = ${sqlString(goal.id)};
      ''');
    }
    return goal;
  }
}
