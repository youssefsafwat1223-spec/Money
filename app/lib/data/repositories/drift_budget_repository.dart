import 'package:drift/drift.dart';

import '../../domain/entities/budget_entity.dart';
import '../../domain/repositories/budget_repository.dart';
import '../db/app_database.dart';
import '../db/sql_value_codec.dart';
import 'drift_repository_support.dart';

class DriftBudgetRepository implements BudgetRepository {
  DriftBudgetRepository(this._db);

  final AppDatabase _db;

  @override
  Future<void> delete(String id) async {
    await _db.customUpdate(
      'DELETE FROM budgets WHERE id = ?;',
      variables: [Variable.withString(id)],
    );
  }

  @override
  Future<List<BudgetEntity>> getAll() async {
    final rows = await _db
        .customSelect(
          'SELECT * FROM budgets ORDER BY start_date DESC;',
        )
        .get();
    return rows.map(budgetFromRow).toList();
  }

  @override
  Future<int> countActive() async {
    final row = await _db.customSelect(
      'SELECT COUNT(*) AS total FROM budgets WHERE is_active = 1;',
    ).getSingle();
    return row.read<int>('total');
  }

  @override
  Future<BudgetEntity?> getById(String id) async {
    final row = await _db.customSelect(
      'SELECT * FROM budgets WHERE id = ? LIMIT 1;',
      variables: [Variable.withString(id)],
    ).getSingleOrNull();
    return row == null ? null : budgetFromRow(row);
  }

  @override
  Future<BudgetEntity> save(BudgetEntity budget) async {
    final existing = await getById(budget.id);
    if (existing == null) {
      await _db.customInsert(
        '''
          INSERT INTO budgets(
            id, category_id, amount, period, start_date, is_active, alert_80_sent, alert_100_sent, show_on_header, account_id
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        ''',
        variables: [
          Variable.withString(budget.id),
          Variable.withString(budget.categoryId),
          Variable.withReal(budget.amount),
          Variable.withString(budgetPeriodToSql(budget.period)),
          Variable.withString(dateTimeToSql(budget.startDate)),
          Variable.withInt(boolToSql(budget.isActive)),
          Variable.withInt(boolToSql(budget.alert80Sent)),
          Variable.withInt(boolToSql(budget.alert100Sent)),
          Variable.withInt(boolToSql(budget.showOnHeader)),
          budget.accountId == null ? const Variable<String>(null) : Variable.withString(budget.accountId!),
        ],
      );
    } else {
      await _db.customUpdate(
        '''
          UPDATE budgets
          SET category_id = ?, amount = ?, period = ?, start_date = ?, is_active = ?,
              alert_80_sent = ?, alert_100_sent = ?, show_on_header = ?, account_id = ?
          WHERE id = ?;
        ''',
        variables: [
          Variable.withString(budget.categoryId),
          Variable.withReal(budget.amount),
          Variable.withString(budgetPeriodToSql(budget.period)),
          Variable.withString(dateTimeToSql(budget.startDate)),
          Variable.withInt(boolToSql(budget.isActive)),
          Variable.withInt(boolToSql(budget.alert80Sent)),
          Variable.withInt(boolToSql(budget.alert100Sent)),
          Variable.withInt(boolToSql(budget.showOnHeader)),
          budget.accountId == null ? const Variable<String>(null) : Variable.withString(budget.accountId!),
          Variable.withString(budget.id),
        ],
      );
    }
    return budget;
  }
}
