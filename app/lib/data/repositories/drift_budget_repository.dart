import 'package:drift/drift.dart';

import '../../domain/entities/budget_entity.dart';
import '../../domain/repositories/budget_repository.dart';
import '../../features/planning_sync/services/planning_outbox_queue.dart';
import '../db/app_database.dart';
import '../db/sql_value_codec.dart';
import 'drift_repository_support.dart';

class DriftBudgetRepository implements BudgetRepository {
  DriftBudgetRepository(this._db, {PlanningOutboxQueue? outboxQueue})
      : _outboxQueue = outboxQueue;

  final AppDatabase _db;
  final PlanningOutboxQueue? _outboxQueue;

  @override
  Future<void> delete(String id) async {
    await _db.transaction(() async {
      final existing = await getById(id);
      final now = dateTimeToSql(DateTime.now().toUtc());
      await _db.customUpdate(
        '''
      UPDATE budgets
      SET deleted_at = ?, is_active = 0
      WHERE id = ?;
      ''',
        variables: [
          Variable.withString(now),
          Variable.withString(id),
        ],
      );
      if (existing != null) {
        await _outboxQueue?.enqueueBudget(
          PlanningSyncOperation.delete,
          existing,
        );
      }
    });
  }

  @override
  Future<List<BudgetEntity>> getAll() async {
    final rows = await _db
        .customSelect(
          'SELECT * FROM budgets WHERE deleted_at IS NULL ORDER BY start_date DESC;',
        )
        .get();
    return rows.map(budgetFromRow).toList();
  }

  @override
  Future<int> countActive() async {
    final row = await _db
        .customSelect(
          'SELECT COUNT(*) AS total FROM budgets WHERE is_active = 1 AND deleted_at IS NULL;',
        )
        .getSingle();
    return row.read<int>('total');
  }

  @override
  Future<BudgetEntity?> getById(String id) async {
    final row = await _db.customSelect(
      'SELECT * FROM budgets WHERE id = ? AND deleted_at IS NULL LIMIT 1;',
      variables: [Variable.withString(id)],
    ).getSingleOrNull();
    return row == null ? null : budgetFromRow(row);
  }

  @override
  Future<BudgetEntity> save(BudgetEntity budget) async {
    return _db.transaction(() async {
      final existing = await getById(budget.id);
      if (existing == null) {
        await _db.customInsert(
          '''
          INSERT INTO budgets(
            id, category_id, amount, period, start_date, is_active, last_notified_spent_amount, last_notified_period_start, show_on_header, account_id
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        ''',
          variables: [
            Variable.withString(budget.id),
            Variable.withString(budget.categoryId),
            Variable.withReal(budget.amount),
            Variable.withString(budgetPeriodToSql(budget.period)),
            Variable.withString(dateTimeToSql(budget.startDate)),
            Variable.withInt(boolToSql(budget.isActive)),
            Variable.withReal(budget.lastNotifiedSpentAmount),
            Variable.withString(dateTimeToSql(budget.lastNotifiedPeriodStart)),
            Variable.withInt(boolToSql(budget.showOnHeader)),
            budget.accountId == null
                ? const Variable<String>(null)
                : Variable.withString(budget.accountId!),
          ],
        );
        await _outboxQueue?.enqueueBudget(
          PlanningSyncOperation.create,
          budget,
        );
      } else {
        await _db.customUpdate(
          '''
          UPDATE budgets
          SET category_id = ?, amount = ?, period = ?, start_date = ?, is_active = ?,
              last_notified_spent_amount = ?, last_notified_period_start = ?, show_on_header = ?, account_id = ?
          WHERE id = ?;
        ''',
          variables: [
            Variable.withString(budget.categoryId),
            Variable.withReal(budget.amount),
            Variable.withString(budgetPeriodToSql(budget.period)),
            Variable.withString(dateTimeToSql(budget.startDate)),
            Variable.withInt(boolToSql(budget.isActive)),
            Variable.withReal(budget.lastNotifiedSpentAmount),
            Variable.withString(dateTimeToSql(budget.lastNotifiedPeriodStart)),
            Variable.withInt(boolToSql(budget.showOnHeader)),
            budget.accountId == null
                ? const Variable<String>(null)
                : Variable.withString(budget.accountId!),
            Variable.withString(budget.id),
          ],
        );
        await _outboxQueue?.enqueueBudget(
          PlanningSyncOperation.update,
          budget,
        );
      }
      return budget;
    });
  }
}
