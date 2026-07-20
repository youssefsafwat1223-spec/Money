import 'dart:convert';

import '../../../core/utils/id_generator.dart';
import '../../../data/db/app_database.dart';
import '../../../data/db/sql_value_codec.dart';
import '../../../domain/entities/account_entity.dart';
import '../../../domain/entities/bill_entity.dart';
import '../../../domain/entities/budget_entity.dart';
import '../../../domain/entities/goal_entity.dart';
import '../../../domain/entities/plan_entity.dart';

enum PlanningSyncOperation { create, update, delete }

class PlanningOutboxItem {
  const PlanningOutboxItem({
    required this.id,
    required this.entityType,
    required this.entityId,
    required this.operation,
    required this.payloadJson,
    required this.attemptCount,
    this.lastError,
    this.nextRetryAt,
  });

  final String id;
  final String entityType;
  final String entityId;
  final PlanningSyncOperation operation;
  final Map<String, dynamic> payloadJson;
  final int attemptCount;
  final String? lastError;
  final DateTime? nextRetryAt;
}

class PlanningOutboxQueue {
  PlanningOutboxQueue({
    required AppDatabase db,
    required bool Function(String entityType) isSyncEnabled,
    required Future<String?> Function() getAuthUserId,
  })  : _db = db,
        _isSyncEnabled = isSyncEnabled,
        _getAuthUserId = getAuthUserId;

  static const int _maxAttempts = 5;
  static const String accountsEntityType = 'account';
  static const String budgetsEntityType = 'budget';
  static const String subscriptionsEntityType = 'subscription';
  static const String goalsEntityType = 'goal';
  static const String plansEntityType = 'plan';

  final AppDatabase _db;
  final bool Function(String entityType) _isSyncEnabled;
  final Future<String?> Function() _getAuthUserId;

  Future<bool> enqueueAccount(
    PlanningSyncOperation op,
    AccountEntity account,
  ) async {
    if (!_isSyncEnabled(accountsEntityType)) return false;
    final userId = await _getAuthUserId();
    if (userId == null) return false;

    final now = dateTimeToSql(DateTime.now().toUtc());
    final payload = _buildAccountPayload(op, account);
    final id = IdGenerator.next();

    await _db.customStatement('''
      INSERT INTO planning_sync_outbox(
        id, entity_type, entity_id, operation, payload_json,
        attempt_count, created_at, updated_at
      ) VALUES (
        ${sqlString(id)},
        ${sqlString(accountsEntityType)},
        ${sqlString(account.id)},
        ${sqlString(op.name)},
        ${sqlString(jsonEncode(payload))},
        0,
        ${sqlString(now)},
        ${sqlString(now)}
      );
    ''');

    await _db.customStatement('''
      UPDATE accounts
      SET sync_status = 'pending'
      WHERE id = ${sqlString(account.id)};
    ''');
    return true;
  }

  Future<bool> enqueueBudget(
    PlanningSyncOperation op,
    BudgetEntity budget,
  ) {
    return _enqueue(
      entityType: budgetsEntityType,
      entityId: budget.id,
      op: op,
      table: 'budgets',
      payload: _buildBudgetPayload(op, budget),
    );
  }

  Future<bool> enqueueSubscription(
    PlanningSyncOperation op,
    BillEntity bill,
  ) {
    return _enqueue(
      entityType: subscriptionsEntityType,
      entityId: bill.id,
      op: op,
      table: 'subscriptions',
      payload: _buildSubscriptionPayload(op, bill),
    );
  }

  Future<bool> enqueueGoal(
    PlanningSyncOperation op,
    GoalEntity goal,
  ) {
    return _enqueue(
      entityType: goalsEntityType,
      entityId: goal.id,
      op: op,
      table: 'goals',
      payload: _buildGoalPayload(op, goal),
    );
  }

  Future<bool> enqueuePlan(
    PlanningSyncOperation op,
    PlanEntity plan,
  ) {
    return _enqueue(
      entityType: plansEntityType,
      entityId: plan.id,
      op: op,
      table: 'plans',
      payload: _buildPlanPayload(op, plan),
    );
  }

  Future<bool> _enqueue({
    required String entityType,
    required String entityId,
    required PlanningSyncOperation op,
    required String table,
    required Map<String, dynamic> payload,
  }) async {
    if (!_isSyncEnabled(entityType)) return false;
    final userId = await _getAuthUserId();
    if (userId == null) return false;

    final now = dateTimeToSql(DateTime.now().toUtc());
    final id = IdGenerator.next();

    await _db.customStatement('''
      INSERT INTO planning_sync_outbox(
        id, entity_type, entity_id, operation, payload_json,
        attempt_count, created_at, updated_at
      ) VALUES (
        ${sqlString(id)},
        ${sqlString(entityType)},
        ${sqlString(entityId)},
        ${sqlString(op.name)},
        ${sqlString(jsonEncode(payload))},
        0,
        ${sqlString(now)},
        ${sqlString(now)}
      );
    ''');

    await _db.customStatement('''
      UPDATE $table
      SET sync_status = 'pending'
      WHERE id = ${sqlString(entityId)};
    ''');
    return true;
  }

  Future<List<PlanningOutboxItem>> pendingItems({
    String? entityType,
    int limit = 50,
  }) async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    final entityClause =
        entityType == null ? '' : 'AND entity_type = ${sqlString(entityType)}';
    final rows = await _db.customSelect('''
      SELECT id, entity_type, entity_id, operation, payload_json,
             attempt_count, last_error, next_retry_at
      FROM planning_sync_outbox
      WHERE attempt_count < $_maxAttempts
        AND (next_retry_at IS NULL OR next_retry_at <= ${sqlString(now)})
        $entityClause
      ORDER BY created_at ASC
      LIMIT $limit;
    ''').get();

    return rows.map((row) {
      final opStr = row.read<String>('operation');
      final op = PlanningSyncOperation.values.firstWhere(
        (e) => e.name == opStr,
        orElse: () => PlanningSyncOperation.update,
      );
      final retryStr = row.readNullable<String>('next_retry_at');
      return PlanningOutboxItem(
        id: row.read<String>('id'),
        entityType: row.read<String>('entity_type'),
        entityId: row.read<String>('entity_id'),
        operation: op,
        payloadJson:
            (jsonDecode(row.read<String>('payload_json')) as Map).cast(),
        attemptCount: row.read<int>('attempt_count'),
        lastError: row.readNullable<String>('last_error'),
        nextRetryAt:
            retryStr == null ? null : DateTime.tryParse(retryStr)?.toUtc(),
      );
    }).toList();
  }

  Future<void> markSuccess(String id) async {
    await _db.customStatement(
      'DELETE FROM planning_sync_outbox WHERE id = ${sqlString(id)};',
    );
  }

  Future<void> markFailed(String id, String error) async {
    final row = await _db
        .customSelect(
          'SELECT attempt_count FROM planning_sync_outbox WHERE id = ${sqlString(id)} LIMIT 1;',
        )
        .getSingleOrNull();
    if (row == null) return;

    final attempts = row.read<int>('attempt_count') + 1;
    final backoffSeconds = _backoff(attempts);
    final nextRetry = dateTimeToSql(
      DateTime.now().toUtc().add(Duration(seconds: backoffSeconds)),
    );
    final now = dateTimeToSql(DateTime.now().toUtc());

    await _db.customStatement('''
      UPDATE planning_sync_outbox
      SET attempt_count = $attempts,
          last_error = ${sqlString(error)},
          next_retry_at = ${sqlString(nextRetry)},
          updated_at = ${sqlString(now)}
      WHERE id = ${sqlString(id)};
    ''');
  }

  static int _backoff(int attempt) => 30 * (1 << (attempt - 1).clamp(0, 7));

  Map<String, dynamic> _buildAccountPayload(
    PlanningSyncOperation op,
    AccountEntity account,
  ) {
    final payload = <String, dynamic>{
      'local_id': account.id,
      'name': account.name,
      'currency': account.currency,
      'type': account.type.name,
      'initial_balance': account.initialBalance,
      'current_balance': account.currentBalance,
      'is_default': account.isDefault,
      'sort_order': account.sortOrder,
      'created_at': account.createdAt.toUtc().toIso8601String(),
      'updated_at': account.updatedAt.toUtc().toIso8601String(),
    };
    if (op == PlanningSyncOperation.delete) {
      payload['deleted_at'] = DateTime.now().toUtc().toIso8601String();
    }
    return payload;
  }

  Map<String, dynamic> _withDelete(
    PlanningSyncOperation op,
    Map<String, dynamic> payload,
  ) {
    if (op == PlanningSyncOperation.delete) {
      payload['deleted_at'] = DateTime.now().toUtc().toIso8601String();
    }
    return payload;
  }

  Map<String, dynamic> _buildBudgetPayload(
    PlanningSyncOperation op,
    BudgetEntity budget,
  ) {
    return _withDelete(op, {
      'local_id': budget.id,
      'category_id': budget.categoryId,
      'amount': budget.amount,
      'period': budget.period.name,
      'start_date': budget.startDate.toUtc().toIso8601String(),
      'is_active': budget.isActive,
      'last_notified_spent_amount': budget.lastNotifiedSpentAmount,
      'last_notified_period_start': budget.lastNotifiedPeriodStart.toUtc().toIso8601String(),
      'show_on_header': budget.showOnHeader,
      'local_account_id': budget.accountId,
    });
  }

  Map<String, dynamic> _buildSubscriptionPayload(
    PlanningSyncOperation op,
    BillEntity bill,
  ) {
    return _withDelete(op, {
      'local_id': bill.id,
      'local_account_id': bill.accountId,
      'merchant_id': bill.merchantId,
      'name': bill.name,
      'amount': bill.amount,
      'currency': bill.currency,
      'type': bill.type.name,
      'frequency': bill.frequency.name,
      'next_due_date': bill.nextDueDate.toUtc().toIso8601String(),
      'reminder_on': bill.reminderOn,
      'is_confirmed': bill.isConfirmed,
      'custom_interval_days': bill.customIntervalDays,
      'note': bill.note,
      'status': bill.status.name,
      'total_installments': bill.totalInstallments,
      'paid_count': bill.paidCount,
      'manual_paid_amount': bill.manualPaidAmount,
      'total_purchase_amount': bill.totalPurchaseAmount,
      'lender_name': bill.lenderName,
      'interest_rate': bill.interestRate,
      'created_at': bill.createdAt.toUtc().toIso8601String(),
    });
  }

  Map<String, dynamic> _buildGoalPayload(
    PlanningSyncOperation op,
    GoalEntity goal,
  ) {
    return _withDelete(op, {
      'local_id': goal.id,
      'local_account_id': goal.accountId,
      'name': goal.name,
      'target_amount': goal.targetAmount,
      'saved_amount': goal.savedAmount,
      'deadline': goal.deadline?.toUtc().toIso8601String(),
      'vault_skin': goal.vaultSkin,
      'status': goal.status,
      'auto_save_amount': goal.autoSaveAmount,
      'auto_save_period': goal.autoSavePeriod,
      'auto_save_last_run': goal.autoSaveLastRun?.toUtc().toIso8601String(),
      'last_notified_saved_amount': goal.lastNotifiedSavedAmount,
      'created_at': goal.createdAt.toUtc().toIso8601String(),
    });
  }

  Map<String, dynamic> _buildPlanPayload(
    PlanningSyncOperation op,
    PlanEntity plan,
  ) {
    return _withDelete(op, {
      'local_id': plan.id,
      'name': plan.name,
      'budget_amount': plan.budgetAmount,
      'currency': plan.currency,
      'start_date': plan.startDate.toUtc().toIso8601String(),
      'end_date': plan.endDate.toUtc().toIso8601String(),
      'local_account_ids': plan.accountIds,
      'card_last4s': plan.cardLast4s,
      'status': plan.status.name,
      'icon': plan.icon,
      'created_at': plan.createdAt.toUtc().toIso8601String(),
    });
  }
}
