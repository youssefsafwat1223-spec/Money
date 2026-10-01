import 'package:drift/drift.dart' show QueryRow;

import '../../data/db/app_database.dart';
import '../../data/db/sql_value_codec.dart';
import '../../data/repositories/drift_account_repository.dart'
    show accountFromRow;
import '../../data/repositories/drift_bill_repository.dart';
import '../../data/repositories/drift_card_repository.dart'
    show cardFromRow;
import '../../data/repositories/drift_plan_repository.dart';
import '../../data/repositories/drift_repository_support.dart'
    show budgetFromRow, goalFromRow, transactionFromRow, userSettingsFromRow;
import '../../domain/entities/category_entity.dart';
import '../../features/capture/services/ledger_outbox_queue.dart';
import '../../features/planning_sync/services/planning_outbox_queue.dart';

/// A-4b — the general safety net behind the raw-SQL bypass writers.
///
/// A writer that changes a synced row outside a repository (a backfill, a
/// cutover, an import, a restore repair) marks every server-backed row it
/// touches `sync_status = 'pending'` ([kMarkPendingIfServerBacked]) but never
/// writes outbox rows itself. Once pulls are enabled such a row, still marked
/// `synced`, would be overwritten by the stale server value; marked `pending`
/// with no outbox row it would sit forever. This reconciler closes the gap: for
/// each synced entity table it finds server-backed `pending` rows that have NO
/// outbox row of any status (pending / parked / dead_letter) and records the
/// intent through the NORMAL queue API (`update`, or `delete` for a tombstoned
/// row), which stamps the owner per the A-2 rules and coalesces.
///
/// Rules:
///  - Rows WITHOUT `server_id` are the backfill services' job — untouched.
///  - A row that already has an outbox row (even a dead letter) is untouched, so
///    a second run enqueues nothing (idempotent, no duplicates).
///  - Consent off (or no owner/session, or owner != signed-in uid) ⇒ does
///    nothing at all. No intent is lost: the `pending` marker persists on the
///    row and the next admitted cycle picks it up.
///  - Bounded: at most [limit] rows per run in total; the remainder is picked up
///    by the next cycle.
///  - Child tables (goal_contributions / bill_payments / plan links) are
///    immutable once written and are not covered.
class PendingSyncReconciler {
  PendingSyncReconciler({
    required AppDatabase db,
    required LedgerOutboxQueue ledgerQueue,
    required PlanningOutboxQueue planningQueue,
    required Future<String?> Function() getOwnerUid,
    required Future<String?> Function() getAuthUserId,
    Future<bool> Function()? mayEgress,
    this.limit = 500,
  })  : _db = db,
        _ledger = ledgerQueue,
        _planning = planningQueue,
        _getOwnerUid = getOwnerUid,
        _getAuthUserId = getAuthUserId,
        _mayEgress = mayEgress ?? _deny;

  static Future<bool> _deny() async => false;

  final AppDatabase _db;
  final LedgerOutboxQueue _ledger;
  final PlanningOutboxQueue _planning;
  final Future<String?> Function() _getOwnerUid;
  final Future<String?> Function() _getAuthUserId;
  final Future<bool> Function() _mayEgress;
  final int limit;

  Future<String?> _safe(Future<String?> Function() read) async {
    try {
      final v = await read();
      return (v == null || v.isEmpty) ? null : v;
    } catch (_) {
      return null;
    }
  }

  /// Returns the number of outbox intents recorded this run.
  Future<int> run() async {
    if (!await _mayEgress()) return 0;
    final owner = await _safe(_getOwnerUid);
    final auth = await _safe(_getAuthUserId);
    // True guest: no identity, no intent. Owner/auth mismatch: never record
    // intent for a different identity than the one signed in.
    if (owner == null && auth == null) return 0;
    if (owner != null && auth != null && owner != auth) return 0;

    var budget = limit;
    var recorded = 0;
    Future<void> each(
      String table,
      String outboxTable,
      String outboxIdCol, {
      String? outboxEntityType,
      String extraWhere = '',
      String extraCols = '',
      bool hasDeletedAt = true,
      required Future<bool> Function(Map<String, Object?> row) enqueue,
    }) async {
      if (budget <= 0) return;
      final typeFilter =
          outboxEntityType == null ? '' : "WHERE entity_type = '$outboxEntityType'";
      final rows = await _db.customSelect('''
        SELECT id, ${hasDeletedAt ? 'deleted_at' : 'NULL AS deleted_at'}$extraCols FROM $table
        WHERE server_id IS NOT NULL AND sync_status = 'pending' $extraWhere
          AND id NOT IN (SELECT $outboxIdCol FROM $outboxTable $typeFilter)
        ORDER BY id LIMIT $budget;
      ''').get();
      for (final r in rows) {
        budget--;
        try {
          if (await enqueue(r.data)) recorded++;
        } catch (_) {
          // A row that cannot be mapped is left pending and stays observable
          // in the unsynced inventory; it must not block the others.
        }
      }
    }

    Future<QueryRow?> one(String table, Object? id) => _db
        .customSelect(
            'SELECT * FROM $table WHERE id = ${sqlString(id! as String)} LIMIT 1;')
        .getSingleOrNull();

    PlanningSyncOperation opOf(Map<String, Object?> r) =>
        r['deleted_at'] == null
            ? PlanningSyncOperation.update
            : PlanningSyncOperation.delete;

    // Transactions (ledger queue). A soft-deleted (ignored) row is a delete.
    await each('transactions', 'ledger_sync_outbox', 'transaction_id',
        extraCols: ', status', hasDeletedAt: false, enqueue: (r) async {
      final row = await one('transactions', r['id']);
      if (row == null) return false;
      await _ledger.enqueue(
        r['status'] == 'ignored' ? OutboxOperation.delete : OutboxOperation.update,
        transactionFromRow(row),
      );
      return true;
    });

    const pe = 'planning_sync_outbox';
    await each('accounts', pe, 'entity_id',
        outboxEntityType: PlanningOutboxQueue.accountsEntityType,
        enqueue: (r) async {
      final row = await one('accounts', r['id']);
      return row != null &&
          await _planning.enqueueAccount(opOf(r), accountFromRow(row));
    });
    await each('budgets', pe, 'entity_id',
        outboxEntityType: PlanningOutboxQueue.budgetsEntityType,
        enqueue: (r) async {
      final row = await one('budgets', r['id']);
      return row != null &&
          await _planning.enqueueBudget(opOf(r), budgetFromRow(row));
    });
    await each('goals', pe, 'entity_id',
        outboxEntityType: PlanningOutboxQueue.goalsEntityType,
        enqueue: (r) async {
      final row = await one('goals', r['id']);
      return row != null &&
          await _planning.enqueueGoal(opOf(r), goalFromRow(row));
    });
    final bills = DriftBillRepository(_db);
    await each('subscriptions', pe, 'entity_id',
        outboxEntityType: PlanningOutboxQueue.subscriptionsEntityType,
        enqueue: (r) async {
      final bill = await bills.getByIdIncludingDeleted(r['id']! as String);
      return bill != null && await _planning.enqueueSubscription(opOf(r), bill);
    });
    final plans = DriftPlanRepository(_db);
    await each('plans', pe, 'entity_id',
        outboxEntityType: PlanningOutboxQueue.plansEntityType,
        enqueue: (r) async {
      final plan = await plans.getByIdIncludingDeleted(r['id']! as String);
      return plan != null && await _planning.enqueuePlan(opOf(r), plan);
    });
    await each('cards', pe, 'entity_id',
        outboxEntityType: PlanningOutboxQueue.cardsEntityType,
        // Account-less cards are local-only while the cards cloud v2 flag is off.
        extraWhere: kUserCardsCloudV2 ? '' : 'AND account_id IS NOT NULL',
        enqueue: (r) async {
      final row = await one('cards', r['id']);
      return row != null &&
          await _planning.enqueueCard(opOf(r), cardFromRow(row));
    });
    await each('categories', pe, 'entity_id',
        outboxEntityType: PlanningOutboxQueue.categoriesEntityType,
        enqueue: (r) async {
      final row = await one('categories', r['id']);
      if (row == null) return false;
      return _planning.enqueueCategory(
        opOf(r),
        CategoryEntity(
          id: row.read<String>('id'),
          key: row.read<String>('key'),
          nameAr: row.read<String>('name_ar'),
          icon: row.read<String>('icon'),
          color: row.read<String>('color'),
          isIncome: sqlToBool(row.read<int>('is_income')),
          sort: row.read<int>('sort_order'),
        ),
      );
    });
    // Settings singleton: only ever an update (it is never tombstoned).
    await each('user_settings', pe, 'entity_id',
        outboxEntityType: PlanningOutboxQueue.settingsEntityType,
        hasDeletedAt: false,
        enqueue: (r) async {
      final row = await one('user_settings', r['id']);
      return row != null &&
          await _planning.enqueueSettings(
              PlanningSyncOperation.update, userSettingsFromRow(row));
    });
    return recorded;
  }
}
