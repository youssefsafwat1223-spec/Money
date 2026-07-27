import 'package:drift/drift.dart';

import '../../domain/entities/plan_entity.dart';
import '../../domain/entities/transaction_entity.dart';
import '../../domain/repositories/plan_repository.dart';
import '../../features/planning_sync/services/planning_outbox_queue.dart';
import '../db/app_database.dart';
import '../db/sql_value_codec.dart';
import 'drift_repository_support.dart';

class DriftPlanRepository implements PlanRepository {
  const DriftPlanRepository(this._db, {PlanningOutboxQueue? outboxQueue})
      : _outboxQueue = outboxQueue;

  final AppDatabase _db;
  final PlanningOutboxQueue? _outboxQueue;

  @override
  Future<List<PlanEntity>> getAll() async {
    final rows = await _db
        .customSelect(
          'SELECT * FROM plans WHERE deleted_at IS NULL ORDER BY created_at DESC;',
        )
        .get();
    return rows.map(_fromRow).toList(growable: false);
  }

  @override
  Future<PlanEntity?> getById(String id) async {
    final row = await _db.customSelect(
      'SELECT * FROM plans WHERE id = ? AND deleted_at IS NULL LIMIT 1;',
      variables: [Variable.withString(id)],
    ).getSingleOrNull();
    return row == null ? null : _fromRow(row);
  }

  @override
  Future<PlanEntity> save(PlanEntity plan) async {
    final existing = await getById(plan.id);
    final vars = [
      Variable.withString(plan.name),
      Variable.withReal(plan.budgetAmount),
      Variable.withString(plan.currency),
      Variable.withString(dateTimeToSql(plan.startDate.toUtc())),
      Variable.withString(dateTimeToSql(plan.endDate.toUtc())),
      Variable.withString(plan.accountIds.join(',')),
      Variable.withString(plan.cardLast4s.join(',')),
      Variable.withString(plan.status.name),
      plan.icon == null
          ? const Variable<String>(null)
          : Variable.withString(plan.icon!),
    ];
    if (existing == null) {
      await _db.customInsert(
        '''
          INSERT INTO plans(
            name, budget_amount, currency, start_date, end_date,
            account_ids, card_last4s, status, icon, created_at, id
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        ''',
        variables: [
          ...vars,
          Variable.withString(dateTimeToSql(plan.createdAt.toUtc())),
          Variable.withString(plan.id),
        ],
      );
      await _outboxQueue?.enqueuePlan(
        PlanningSyncOperation.create,
        plan,
      );
    } else {
      await _db.customUpdate(
        '''
          UPDATE plans SET
            name = ?, budget_amount = ?, currency = ?, start_date = ?,
            end_date = ?, account_ids = ?, card_last4s = ?, status = ?, icon = ?
          WHERE id = ?;
        ''',
        variables: [...vars, Variable.withString(plan.id)],
      );
      await _outboxQueue?.enqueuePlan(
        PlanningSyncOperation.update,
        plan,
      );
    }
    return plan;
  }

  @override
  Future<void> delete(String id) async {
    final existing = await getById(id);
    final now = dateTimeToSql(DateTime.now().toUtc());
    await _db.customUpdate(
      '''
      UPDATE plans
      SET deleted_at = ?, status = 'closed'
      WHERE id = ?;
      ''',
      variables: [
        Variable.withString(now),
        Variable.withString(id),
      ],
    );
    if (existing != null) {
      await _outboxQueue?.enqueuePlan(
        PlanningSyncOperation.delete,
        existing,
      );
    }
  }

  @override
  Future<double> spentForPlan(PlanEntity plan) async {
    final membership = _membershipSql(plan);
    final row = await _db.customSelect(
      '''
        SELECT CAST(COALESCE(SUM(amount), 0) AS REAL) AS total
        FROM (
          SELECT DISTINCT t.id, t.amount
          FROM transactions t
          LEFT JOIN plan_transaction_links ptl
            ON ptl.transaction_id = t.id AND ptl.plan_id = ?
              AND ptl.deleted_at IS NULL
          WHERE t.type IN ('payment', 'withdrawal')
            AND t.status = 'confirmed'
            AND (${membership.whereSql} OR ptl.plan_id IS NOT NULL)
        );
      ''',
      variables: [Variable.withString(plan.id), ...membership.variables],
    ).getSingle();
    return row.read<double>('total');
  }

  @override
  Future<List<TransactionEntity>> transactionsForPlan(PlanEntity plan) async {
    final membership = _membershipSql(plan);
    final rows = await _db.customSelect(
      '''
        SELECT DISTINCT t.*
        FROM transactions t
          LEFT JOIN plan_transaction_links ptl
            ON ptl.transaction_id = t.id AND ptl.plan_id = ?
              AND ptl.deleted_at IS NULL
        WHERE t.type IN ('payment', 'withdrawal')
          AND t.status = 'confirmed'
          AND (${membership.whereSql} OR ptl.plan_id IS NOT NULL)
        ORDER BY t.occurred_at DESC;
      ''',
      variables: [Variable.withString(plan.id), ...membership.variables],
    ).get();
    return rows.map(transactionFromRow).toList(growable: false);
  }

  @override
  Future<void> linkTransactionToPlan({
    required String planId,
    required String transactionId,
  }) async {
    await _db.customInsert(
      '''
        INSERT INTO plan_transaction_links(plan_id, transaction_id, created_at, deleted_at)
        VALUES (?, ?, ?, NULL)
        ON CONFLICT(plan_id, transaction_id) DO UPDATE SET deleted_at = NULL;
      ''',
      variables: [
        Variable.withString(planId),
        Variable.withString(transactionId),
        Variable.withString(dateTimeToSql(DateTime.now().toUtc())),
      ],
    );
    await _outboxQueue?.enqueuePlanLink(
      PlanningSyncOperation.create,
      planId: planId,
      transactionId: transactionId,
      createdAt: DateTime.now().toUtc(),
    );
  }

  @override
  Future<void> unlinkTransactionFromPlan({
    required String planId,
    required String transactionId,
  }) async {
    final now = DateTime.now().toUtc();
    await _db.customUpdate(
      'UPDATE plan_transaction_links SET deleted_at = ? '
      'WHERE plan_id = ? AND transaction_id = ?;',
      variables: [
        Variable.withString(dateTimeToSql(now)),
        Variable.withString(planId),
        Variable.withString(transactionId),
      ],
    );
    await _outboxQueue?.enqueuePlanLink(
      PlanningSyncOperation.delete,
      planId: planId,
      transactionId: transactionId,
      createdAt: now,
    );
  }

  _PlanMembershipSql _membershipSql(PlanEntity plan) {
    final vars = <Variable>[
      Variable.withString(dateTimeToSql(plan.startDate.toUtc())),
      Variable.withString(dateTimeToSql(plan.endDate.toUtc())),
    ];
    final parts = <String>['t.occurred_at BETWEEN ? AND ?'];
    final scopeParts = <String>[];
    if (plan.accountIds.isNotEmpty) {
      final marks = List.filled(plan.accountIds.length, '?').join(',');
      scopeParts.add('t.account_id IN ($marks)');
      vars.addAll(plan.accountIds.map(Variable.withString));
    }
    if (plan.cardLast4s.isNotEmpty) {
      final marks = List.filled(plan.cardLast4s.length, '?').join(',');
      scopeParts.add('t.card_last4 IN ($marks)');
      vars.addAll(plan.cardLast4s.map(Variable.withString));
    }
    if (scopeParts.isNotEmpty) {
      parts.add('(${scopeParts.join(' OR ')})');
    }
    return _PlanMembershipSql(parts.join(' AND '), vars);
  }

  PlanEntity _fromRow(QueryRow row) {
    List<String> csv(String column) => row
        .read<String>(column)
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
    return PlanEntity(
      id: row.read<String>('id'),
      name: row.read<String>('name'),
      budgetAmount: row.read<double>('budget_amount'),
      currency: row.read<String>('currency'),
      startDate: dateTimeFromSql(row.read<String>('start_date')),
      endDate: dateTimeFromSql(row.read<String>('end_date')),
      accountIds: csv('account_ids'),
      cardLast4s: csv('card_last4s'),
      status: row.read<String>('status') == 'closed'
          ? PlanStatus.closed
          : PlanStatus.active,
      icon: row.readNullable<String>('icon'),
      createdAt: dateTimeFromSql(row.read<String>('created_at')),
    );
  }
}

class _PlanMembershipSql {
  const _PlanMembershipSql(this.whereSql, this.variables);

  final String whereSql;
  final List<Variable> variables;
}
