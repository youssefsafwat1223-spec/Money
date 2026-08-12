import 'package:drift/drift.dart';

import '../../domain/entities/budget_entity.dart';
import '../../domain/finance/planning_mutation_guard.dart';
import '../../domain/repositories/budget_repository.dart';
import '../../features/planning_sync/services/planning_outbox_queue.dart';
import '../db/app_database.dart';
import '../db/money_codec.dart';
import '../db/planning_cutover.dart';
import '../db/sql_value_codec.dart';
import 'drift_repository_support.dart';

/// MALI-026 (B8-3 §8/§9/§10, correction 4) — the CANONICAL budget repository.
/// It operates only in P3 (canonical): reads build Money from `row.currency` +
/// `_minor`, writes dual-bind `_minor` (authority) + REAL (shadow) from the
/// entity's Money. In P1 (unresolved) it REFUSES both reads and writes with a
/// typed [PlanningCurrencyRepairRequired] — the correctness boundary lives here,
/// below navigation. The repair screen uses its own legacy-safe raw read model.
class DriftBudgetRepository implements BudgetRepository {
  DriftBudgetRepository(
    this._db, {
    PlanningOutboxQueue? outboxQueue,
    // A directly-constructed repo defaults to canonical (a fresh v30 DB is
    // canonical); production injects the real DB-marker coordinator, and P1 tests
    // inject unresolved.
    PlanningCutoverCoordinator coordinator =
        const FixedPlanningCutoverCoordinator(PlanningCutoverState.canonical),
  })  : _outboxQueue = outboxQueue,
        _coordinator = coordinator,
        _guard = PlanningMutationGuard(coordinator);

  final AppDatabase _db;
  final PlanningOutboxQueue? _outboxQueue;
  final PlanningCutoverCoordinator _coordinator;
  final PlanningMutationGuard _guard;

  /// P1 read refusal (correction 4): a canonical read is only valid once the
  /// dataset is canonical. Never reads legacy REAL as canonical.
  void _requireCanonicalRead() {
    if (_coordinator.state() != PlanningCutoverState.canonical) {
      throw const PlanningCurrencyRepairRequired(
          'planning is unresolved — canonical budget reads are unavailable');
    }
  }

  @override
  Future<void> delete(String id) async {
    _guard.requireDeletable();
    await _db.transaction(() async {
      final existing = await getById(id);
      final now = dateTimeToSql(DateTime.now().toUtc());
      await _db.customUpdate(
        'UPDATE budgets SET deleted_at = ?, is_active = 0 WHERE id = ?;',
        variables: [Variable.withString(now), Variable.withString(id)],
      );
      if (existing != null) {
        await _outboxQueue?.enqueueBudget(PlanningSyncOperation.delete, existing);
      }
    });
  }

  @override
  Future<List<BudgetEntity>> getAll() async {
    _requireCanonicalRead();
    final rows = await _db
        .customSelect(
          'SELECT * FROM budgets WHERE deleted_at IS NULL ORDER BY start_date DESC;',
        )
        .get();
    return rows.map(budgetFromRow).toList();
  }

  @override
  Future<int> countActive() async {
    _requireCanonicalRead();
    final row = await _db
        .customSelect(
          'SELECT COUNT(*) AS total FROM budgets WHERE is_active = 1 AND deleted_at IS NULL;',
        )
        .getSingle();
    return row.read<int>('total');
  }

  @override
  Future<BudgetEntity?> getById(String id) async {
    _requireCanonicalRead();
    final row = await _db.customSelect(
      'SELECT * FROM budgets WHERE id = ? AND deleted_at IS NULL LIMIT 1;',
      variables: [Variable.withString(id)],
    ).getSingleOrNull();
    return row == null ? null : budgetFromRow(row);
  }

  @override
  Future<BudgetEntity> save(BudgetEntity budget) async {
    _guard.requireMutable();
    return _db.transaction(() async {
      final existing = await getById(budget.id);
      // §10 / correction 5 — CREATE accepts the entity's (base-seeded) currency;
      // UPDATE preserves the persisted row currency and REJECTS an unexpected
      // change (currency conversion is a separate authorized workflow, not an
      // ordinary edit).
      if (existing != null && existing.currency != budget.currency) {
        throw StateError(
          'budget ${budget.id}: currency change ${existing.currency} -> '
          '${budget.currency} is not allowed on update',
        );
      }
      final currency = existing?.currency ?? budget.currency;
      if (existing == null) {
        await _db.customInsert(
          '''
          INSERT INTO budgets(
            id, category_id, currency, amount, amount_minor, period, start_date,
            is_active, last_notified_spent_amount, last_notified_spent_amount_minor,
            last_notified_period_start, show_on_header, account_id
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        ''',
          variables: [
            Variable.withString(budget.id),
            Variable.withString(budget.categoryId),
            Variable.withString(currency),
            kMoneyCodec.realVar(budget.amountMoney),
            kMoneyCodec.minorVar(budget.amountMoney),
            Variable.withString(budgetPeriodToSql(budget.period)),
            Variable.withString(dateTimeToSql(budget.startDate)),
            Variable.withInt(boolToSql(budget.isActive)),
            kMoneyCodec.realVar(budget.lastNotifiedSpentMoney),
            kMoneyCodec.minorVar(budget.lastNotifiedSpentMoney),
            Variable.withString(dateTimeToSql(budget.lastNotifiedPeriodStart)),
            Variable.withInt(boolToSql(budget.showOnHeader)),
            budget.accountId == null
                ? const Variable<String>(null)
                : Variable.withString(budget.accountId!),
          ],
        );
        await _outboxQueue?.enqueueBudget(PlanningSyncOperation.create, budget);
      } else {
        await _db.customUpdate(
          '''
          UPDATE budgets
          SET category_id = ?, amount = ?, amount_minor = ?, period = ?,
              start_date = ?, is_active = ?, last_notified_spent_amount = ?,
              last_notified_spent_amount_minor = ?, last_notified_period_start = ?,
              show_on_header = ?, account_id = ?
          WHERE id = ?;
        ''',
          variables: [
            Variable.withString(budget.categoryId),
            kMoneyCodec.realVar(budget.amountMoney),
            kMoneyCodec.minorVar(budget.amountMoney),
            Variable.withString(budgetPeriodToSql(budget.period)),
            Variable.withString(dateTimeToSql(budget.startDate)),
            Variable.withInt(boolToSql(budget.isActive)),
            kMoneyCodec.realVar(budget.lastNotifiedSpentMoney),
            kMoneyCodec.minorVar(budget.lastNotifiedSpentMoney),
            Variable.withString(dateTimeToSql(budget.lastNotifiedPeriodStart)),
            Variable.withInt(boolToSql(budget.showOnHeader)),
            budget.accountId == null
                ? const Variable<String>(null)
                : Variable.withString(budget.accountId!),
            Variable.withString(budget.id),
          ],
        );
        await _outboxQueue?.enqueueBudget(PlanningSyncOperation.update, budget);
      }
      return budget;
    });
  }
}
