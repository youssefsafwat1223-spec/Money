import 'package:drift/drift.dart';

import '../../domain/entities/goal_entity.dart';
import '../../domain/finance/planning_mutation_guard.dart';
import '../../domain/repositories/goal_repository.dart';
import '../../features/planning_sync/services/planning_outbox_queue.dart';
import '../db/app_database.dart';
import '../db/money_codec.dart';
import '../db/planning_cutover.dart';
import '../db/sql_value_codec.dart';
import 'drift_repository_support.dart';

/// MALI-026 (B8-3 §8/§9/§10/§14, correction 4) — the CANONICAL goal repository.
/// P3 reads build Money from `row.currency` + `_minor`; writes dual-bind
/// `_minor` (authority) + REAL (shadow). Contributions inherit the parent goal's
/// currency (resolved by a JOIN — no N+1). In P1 it REFUSES reads and writes.
class DriftGoalRepository implements GoalRepository {
  DriftGoalRepository(
    this._db, {
    PlanningOutboxQueue? outboxQueue,
    PlanningCutoverCoordinator coordinator =
        const FixedPlanningCutoverCoordinator(PlanningCutoverState.canonical),
  })  : _outboxQueue = outboxQueue,
        _coordinator = coordinator,
        _guard = PlanningMutationGuard(coordinator);

  final AppDatabase _db;
  final PlanningOutboxQueue? _outboxQueue;
  final PlanningCutoverCoordinator _coordinator;
  final PlanningMutationGuard _guard;

  void _requireCanonicalRead() {
    if (_coordinator.state() != PlanningCutoverState.canonical) {
      throw const PlanningCurrencyRepairRequired(
          'planning is unresolved — canonical goal reads are unavailable');
    }
  }

  @override
  Future<GoalContributionEntity> addContribution(
    GoalContributionEntity contribution,
  ) async {
    _guard.requireMutable();
    return _db.transaction(() async {
      // The contribution's currency MUST equal the parent goal's currency (§14).
      final goal = await getById(contribution.goalId);
      if (goal == null) {
        throw StateError('goal ${contribution.goalId} not found');
      }
      if (contribution.amountMoney.currency != goal.currency) {
        throw StateError(
          'contribution currency ${contribution.amountMoney.currency} != parent '
          'goal currency ${goal.currency}',
        );
      }
      await _db.customStatement('''
      INSERT INTO goal_contributions(id, goal_id, amount, amount_minor, created_at, note)
      VALUES (
        ${sqlString(contribution.id)},
        ${sqlString(contribution.goalId)},
        ${kMoneyCodec.sqlRealLiteral(contribution.amountMoney)},
        ${kMoneyCodec.sqlMinorLiteral(contribution.amountMoney)},
        ${sqlString(dateTimeToSql(contribution.createdAt))},
        ${sqlNullableString(contribution.note)}
      );
    ''');

      await _db.customUpdate(
        'UPDATE goals SET saved_amount = saved_amount + ?, '
        'saved_amount_minor = saved_amount_minor + ? WHERE id = ?;',
        variables: [
          kMoneyCodec.realVar(contribution.amountMoney),
          kMoneyCodec.minorVar(contribution.amountMoney),
          Variable.withString(contribution.goalId),
        ],
      );
      await _outboxQueue?.enqueueGoalContribution(
          PlanningSyncOperation.create, contribution);
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
        "UPDATE goals SET deleted_at = ?, status = 'archived' WHERE id = ?;",
        variables: [Variable.withString(now), Variable.withString(id)],
      );
      if (existing != null) {
        await _outboxQueue?.enqueueGoal(PlanningSyncOperation.delete, existing);
      }
    });
  }

  @override
  Future<int> countAll() async {
    _requireCanonicalRead();
    final row = await _db
        .customSelect('SELECT COUNT(*) AS total FROM goals WHERE deleted_at IS NULL;')
        .getSingle();
    return row.read<int>('total');
  }

  @override
  Future<List<GoalEntity>> getAll() async {
    _requireCanonicalRead();
    final rows = await _db
        .customSelect(
          'SELECT * FROM goals WHERE deleted_at IS NULL ORDER BY created_at DESC;',
        )
        .get();
    return rows.map(goalFromRow).toList();
  }

  @override
  Future<GoalEntity?> getById(String id) async {
    _requireCanonicalRead();
    final row = await _db.customSelect(
      'SELECT * FROM goals WHERE id = ? AND deleted_at IS NULL LIMIT 1;',
      variables: [Variable.withString(id)],
    ).getSingleOrNull();
    return row == null ? null : goalFromRow(row);
  }

  @override
  Future<List<GoalContributionEntity>> getContributions(String goalId) async {
    _requireCanonicalRead();
    final rows = await _db.customSelect(
      '''
        SELECT gc.id AS id, gc.goal_id AS goal_id, gc.amount AS amount,
               gc.amount_minor AS amount_minor, gc.created_at AS created_at,
               gc.note AS note, g.currency AS goal_currency
        FROM goal_contributions gc
        JOIN goals g ON g.id = gc.goal_id
        WHERE gc.goal_id = ? AND gc.deleted_at IS NULL
        ORDER BY gc.created_at DESC;
      ''',
      variables: [Variable.withString(goalId)],
    ).get();
    return rows
        .map((r) => goalContributionFromRow(r, r.read<String>('goal_currency')))
        .toList();
  }

  @override
  Future<GoalEntity> save(GoalEntity goal) async {
    _guard.requireMutable();
    return _db.transaction(() async {
      final existing = await getById(goal.id);
      if (existing != null && existing.currency != goal.currency) {
        throw StateError(
          'goal ${goal.id}: currency change ${existing.currency} -> '
          '${goal.currency} is not allowed on update',
        );
      }
      final currency = existing?.currency ?? goal.currency;
      final autoReal = kMoneyCodec.sqlNullableRealLiteral(goal.autoSaveMoney);
      final autoMinor = kMoneyCodec.sqlNullableMinorLiteral(goal.autoSaveMoney);
      final autoPeriod = sqlNullableString(goal.autoSavePeriod);
      final autoLastRun = sqlNullableString(goal.autoSaveLastRun == null
          ? null
          : dateTimeToSql(goal.autoSaveLastRun!));
      if (existing == null) {
        await _db.customStatement('''
        INSERT INTO goals(
          id, name, account_id, currency, target_amount, target_amount_minor,
          saved_amount, saved_amount_minor, deadline, vault_skin, status,
          created_at, last_notified_saved_amount, last_notified_saved_amount_minor,
          auto_save_amount, auto_save_amount_minor, auto_save_period, auto_save_last_run
        ) VALUES (
          ${sqlString(goal.id)},
          ${sqlString(goal.name)},
          ${sqlNullableString(goal.accountId)},
          ${sqlString(currency)},
          ${kMoneyCodec.sqlRealLiteral(goal.targetMoney)},
          ${kMoneyCodec.sqlMinorLiteral(goal.targetMoney)},
          ${kMoneyCodec.sqlRealLiteral(goal.savedMoney)},
          ${kMoneyCodec.sqlMinorLiteral(goal.savedMoney)},
          ${sqlNullableString(goal.deadline == null ? null : dateTimeToSql(goal.deadline!))},
          ${sqlString(goal.vaultSkin)},
          ${sqlString(goal.status)},
          ${sqlString(dateTimeToSql(goal.createdAt))},
          ${kMoneyCodec.sqlRealLiteral(goal.lastNotifiedSavedMoney)},
          ${kMoneyCodec.sqlMinorLiteral(goal.lastNotifiedSavedMoney)},
          $autoReal, $autoMinor, $autoPeriod, $autoLastRun
        );
      ''');
        await _outboxQueue?.enqueueGoal(PlanningSyncOperation.create, goal);
      } else {
        await _db.customStatement('''
        UPDATE goals
        SET name = ${sqlString(goal.name)},
            account_id = ${sqlNullableString(goal.accountId)},
            target_amount = ${kMoneyCodec.sqlRealLiteral(goal.targetMoney)},
            target_amount_minor = ${kMoneyCodec.sqlMinorLiteral(goal.targetMoney)},
            saved_amount = ${kMoneyCodec.sqlRealLiteral(goal.savedMoney)},
            saved_amount_minor = ${kMoneyCodec.sqlMinorLiteral(goal.savedMoney)},
            deadline = ${sqlNullableString(goal.deadline == null ? null : dateTimeToSql(goal.deadline!))},
            vault_skin = ${sqlString(goal.vaultSkin)},
            status = ${sqlString(goal.status)},
            created_at = ${sqlString(dateTimeToSql(goal.createdAt))},
            last_notified_saved_amount = ${kMoneyCodec.sqlRealLiteral(goal.lastNotifiedSavedMoney)},
            last_notified_saved_amount_minor = ${kMoneyCodec.sqlMinorLiteral(goal.lastNotifiedSavedMoney)},
            auto_save_amount = $autoReal,
            auto_save_amount_minor = $autoMinor,
            auto_save_period = $autoPeriod,
            auto_save_last_run = $autoLastRun
        WHERE id = ${sqlString(goal.id)};
      ''');
        await _outboxQueue?.enqueueGoal(PlanningSyncOperation.update, goal);
      }
      return goal;
    });
  }
}
