import '../../../data/db/app_database.dart';
import '../../../data/db/sql_value_codec.dart';
import '../../../domain/repositories/bill_repository.dart';
import '../../../domain/repositories/budget_repository.dart';
import '../../../domain/repositories/goal_repository.dart';
import '../../../domain/repositories/plan_repository.dart';
import 'planning_outbox_queue.dart';
import 'planning_push_service.dart';

/// A planning row stuck in `sync_status='conflict'` (a genuine two-device edit
/// collision after MALI-022 part 1), surfaced for the user to resolve.
class PlanningConflict {
  const PlanningConflict({
    required this.entityType,
    required this.localId,
    required this.label,
  });

  final String entityType;
  final String localId;
  final String label;
}

/// MALI-022 part 2 — visible conflict resolution. Conflicts used to be flagged
/// and then left forever with no way out; this lists them and lets the user
/// pick a side, reusing the normal push/pull machinery to carry the decision:
///   • keep-mine  → refresh the base to the current server version and
///     re-enqueue, so the next push overwrites the remote row.
///   • keep-theirs→ mark synced with a stale base, so the next pull overwrites
///     the local row with the server's version.
/// Either way the `conflict` flag is cleared and the row rejoins normal sync.
class PlanningConflictResolver {
  PlanningConflictResolver({
    required AppDatabase db,
    required PlanningOutboxQueue queue,
    required BudgetRepository budgets,
    required GoalRepository goals,
    required BillRepository bills,
    required PlanRepository plans,
    PlanningRemoteSink? remoteSink,
  })  : _db = db,
        _queue = queue,
        _budgets = budgets,
        _goals = goals,
        _bills = bills,
        _plans = plans,
        _remoteSink = remoteSink ?? const SupabasePlanningRemoteSink();

  final AppDatabase _db;
  final PlanningOutboxQueue _queue;
  final BudgetRepository _budgets;
  final GoalRepository _goals;
  final BillRepository _bills;
  final PlanRepository _plans;
  final PlanningRemoteSink _remoteSink;

  static const _localTable = {
    PlanningOutboxQueue.budgetsEntityType: 'budgets',
    PlanningOutboxQueue.goalsEntityType: 'goals',
    PlanningOutboxQueue.subscriptionsEntityType: 'subscriptions',
    PlanningOutboxQueue.plansEntityType: 'plans',
  };

  static const _remoteTable = {
    PlanningOutboxQueue.budgetsEntityType: 'user_budgets',
    PlanningOutboxQueue.goalsEntityType: 'user_goals',
    PlanningOutboxQueue.subscriptionsEntityType: 'user_subscriptions',
    PlanningOutboxQueue.plansEntityType: 'user_plans',
  };

  /// The label column to show per entity (budgets have no name → amount).
  static const _labelSql = {
    PlanningOutboxQueue.budgetsEntityType: "'ميزانية ' || CAST(amount AS TEXT)",
    PlanningOutboxQueue.goalsEntityType: 'name',
    PlanningOutboxQueue.subscriptionsEntityType: 'name',
    PlanningOutboxQueue.plansEntityType: 'name',
  };

  Future<List<PlanningConflict>> listConflicts() async {
    final out = <PlanningConflict>[];
    for (final entry in _localTable.entries) {
      final table = entry.value;
      final label = _labelSql[entry.key]!;
      final rows = await _db
          .customSelect(
            "SELECT id, ($label) AS label FROM $table "
            "WHERE sync_status = 'conflict' AND deleted_at IS NULL "
            'ORDER BY id;',
          )
          .get();
      for (final row in rows) {
        out.add(PlanningConflict(
          entityType: entry.key,
          localId: row.read<String>('id'),
          label: row.readNullable<String>('label') ?? row.read<String>('id'),
        ));
      }
    }
    return out;
  }

  /// Keep the local edit: refresh the base to the current server version and
  /// re-enqueue an update so the next push cleanly overwrites the remote row.
  Future<void> resolveKeepLocal(String entityType, String localId) async {
    final table = _localTable[entityType];
    final remoteTable = _remoteTable[entityType];
    if (table == null || remoteTable == null) return;

    final serverId = await _serverId(table, localId);
    if (serverId != null) {
      final current =
          await _remoteSink.fetchServerUpdatedAt(remoteTable, serverId);
      if (current != null) {
        await _db.customStatement(
          'UPDATE $table SET server_updated_at = ${sqlString(current)} '
          'WHERE id = ${sqlString(localId)};',
        );
      }
    }
    // Re-enqueue the current local entity as an update (captures the refreshed
    // base), then clear the conflict flag → the row rejoins the push queue.
    await _reEnqueue(entityType, localId);
    await _db.customStatement(
      "UPDATE $table SET sync_status = 'pending' WHERE id = ${sqlString(localId)};",
    );
  }

  /// Keep the remote edit: drop any queued local change and mark the row synced
  /// with its stale base, so the next pull (which detects the server moved past
  /// that base) overwrites the local row with the server's version.
  Future<void> resolveKeepRemote(String entityType, String localId) async {
    final table = _localTable[entityType];
    if (table == null) return;
    await _removeOutbox(entityType, localId);
    await _db.customStatement(
      "UPDATE $table SET sync_status = 'synced' WHERE id = ${sqlString(localId)};",
    );
  }

  Future<String?> _serverId(String table, String localId) async {
    final row = await _db
        .customSelect(
          'SELECT server_id FROM $table WHERE id = ${sqlString(localId)} LIMIT 1;',
        )
        .getSingleOrNull();
    return row?.readNullable<String>('server_id');
  }

  Future<void> _removeOutbox(String entityType, String localId) async {
    await _db.customStatement(
      'DELETE FROM planning_sync_outbox '
      'WHERE entity_type = ${sqlString(entityType)} '
      'AND entity_id = ${sqlString(localId)};',
    );
  }

  Future<void> _reEnqueue(String entityType, String localId) async {
    switch (entityType) {
      case PlanningOutboxQueue.budgetsEntityType:
        final e = await _budgets.getById(localId);
        if (e != null) {
          await _queue.enqueueBudget(PlanningSyncOperation.update, e);
        }
      case PlanningOutboxQueue.goalsEntityType:
        final e = await _goals.getById(localId);
        if (e != null) {
          await _queue.enqueueGoal(PlanningSyncOperation.update, e);
        }
      case PlanningOutboxQueue.subscriptionsEntityType:
        final e = await _bills.getById(localId);
        if (e != null) {
          await _queue.enqueueSubscription(PlanningSyncOperation.update, e);
        }
      case PlanningOutboxQueue.plansEntityType:
        final e = await _plans.getById(localId);
        if (e != null) {
          await _queue.enqueuePlan(PlanningSyncOperation.update, e);
        }
    }
  }
}
