import 'package:drift/drift.dart' show QueryRow;

import '../../data/db/app_database.dart';
import '../../data/db/sql_value_codec.dart';
import '../../data/repositories/drift_account_repository.dart'
    show accountFromRow;
import '../../data/repositories/drift_bill_repository.dart';
import '../../data/repositories/drift_card_repository.dart' show cardFromRow;
import '../../data/repositories/drift_plan_repository.dart';
import '../../data/repositories/drift_repository_support.dart'
    show
        budgetFromRow,
        goalContributionFromRow,
        goalFromRow,
        transactionFromRow,
        userSettingsFromRow;
import '../../domain/entities/category_entity.dart';
import '../../features/capture/services/ledger_outbox_queue.dart';
import '../../features/planning_sync/services/planning_outbox_queue.dart';
import 'sync_health.dart';

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
///  - Bounded: at most [limit] RECORDED rows per run in total, shared fairly
///    across tables (each gets a quota first); the remainder is picked up by the
///    next cycle. Rows that fail to map/enqueue neither consume the budget nor
///    block later rows/tables (keyset `id > :lastId` per table); they stay
///    `pending`, are reported once per table per run as a coarse SyncHealth
///    failure, and remain visible to the unsynced inventory.
///  - Child tables (goal_contributions / bill_payments / plan links) are
///    immutable (create/delete only), so the only valid ops are `create` (an
///    idempotent re-push by client_request_id) and, for a tombstoned row,
///    `delete`. A tombstoned goal contribution has NO valid op (the server has
///    no delete endpoint — the child push dead-letters it), so it is left
///    `pending` and unqueued rather than inventing one.
class PendingSyncReconciler {
  PendingSyncReconciler({
    required AppDatabase db,
    required LedgerOutboxQueue ledgerQueue,
    required PlanningOutboxQueue planningQueue,
    required Future<String?> Function() getOwnerUid,
    required Future<String?> Function() getAuthUserId,
    Future<bool> Function()? mayEgress,
    this.health,
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
  final SyncHealth? health;
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
    final sources = <_Source>[];
    void each(
      String table,
      String outboxTable,
      String outboxIdCol, {
      String? outboxEntityType,
      String extraWhere = '',
      String extraCols = '',
      // Entity key expression for tables with no `id` column (plan links).
      String idExpr = 'id',
      bool hasDeletedAt = true,
      SyncDomain domain = SyncDomain.planning,
      required Future<bool> Function(Map<String, Object?> row) enqueue,
    }) {
      final typeFilter = outboxEntityType == null
          ? ''
          : "WHERE entity_type = '$outboxEntityType'";
      sources.add(_Source(
        domain: domain,
        enqueue: enqueue,
        // Keyset page: `id > :lastId` so a row that fails is simply stepped
        // over for this run and can never pin the window.
        sql: (lastId, pageSize) => '''
          SELECT $idExpr AS id, ${hasDeletedAt ? 'deleted_at' : 'NULL AS deleted_at'}$extraCols FROM $table
          WHERE server_id IS NOT NULL AND sync_status = 'pending' $extraWhere
            AND $idExpr NOT IN (SELECT $outboxIdCol FROM $outboxTable $typeFilter)
            AND $idExpr > ${sqlString(lastId)}
          ORDER BY $idExpr LIMIT $pageSize;
        ''',
      ));
    }

    // Pass 1 gives every table a fair quota of the shared budget; pass 2 spends
    // whatever is left in table order. The budget is spent only on rows that are
    // actually RECORDED — a row that fails to map/enqueue is skipped for this
    // run (coarse failure to SyncHealth, no row data) without consuming budget
    // or blocking the rows and tables behind it.
    Future<void> drain(_Source src, int maxRecorded) async {
      var got = 0;
      while (budget > 0 && got < maxRecorded && !src.exhausted) {
        final rows =
            await _db.customSelect(src.sql(src.lastId, _pageSize)).get();
        if (rows.isEmpty) {
          src.exhausted = true;
          return;
        }
        for (final r in rows) {
          src.lastId = r.data['id']! as String;
          try {
            if (await src.enqueue(r.data)) {
              recorded++;
              got++;
              budget--;
            }
          } catch (e) {
            if (!src.failureReported) {
              src.failureReported = true;
              health?.recordFailure(src.domain, e);
            }
            // The row stays `pending` with no outbox row, so it remains visible
            // in the unsynced inventory; it must not block the others.
          }
          if (budget <= 0 || got >= maxRecorded) return;
        }
        if (rows.length < _pageSize) src.exhausted = true;
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
    each('transactions', 'ledger_sync_outbox', 'transaction_id',
        extraCols: ', status',
        hasDeletedAt: false,
        domain: SyncDomain.ledger, enqueue: (r) async {
      final row = await one('transactions', r['id']);
      if (row == null) return false;
      await _ledger.enqueue(
        r['status'] == 'ignored'
            ? OutboxOperation.delete
            : OutboxOperation.update,
        transactionFromRow(row),
      );
      return true;
    });

    const pe = 'planning_sync_outbox';
    each('accounts', pe, 'entity_id',
        outboxEntityType: PlanningOutboxQueue.accountsEntityType,
        enqueue: (r) async {
      final row = await one('accounts', r['id']);
      return row != null &&
          await _planning.enqueueAccount(opOf(r), accountFromRow(row));
    });
    each('budgets', pe, 'entity_id',
        outboxEntityType: PlanningOutboxQueue.budgetsEntityType,
        enqueue: (r) async {
      final row = await one('budgets', r['id']);
      return row != null &&
          await _planning.enqueueBudget(opOf(r), budgetFromRow(row));
    });
    each('goals', pe, 'entity_id',
        outboxEntityType: PlanningOutboxQueue.goalsEntityType,
        enqueue: (r) async {
      final row = await one('goals', r['id']);
      return row != null &&
          await _planning.enqueueGoal(opOf(r), goalFromRow(row));
    });
    final bills = DriftBillRepository(_db);
    each('subscriptions', pe, 'entity_id',
        outboxEntityType: PlanningOutboxQueue.subscriptionsEntityType,
        enqueue: (r) async {
      final bill = await bills.getByIdIncludingDeleted(r['id']! as String);
      return bill != null && await _planning.enqueueSubscription(opOf(r), bill);
    });
    final plans = DriftPlanRepository(_db);
    each('plans', pe, 'entity_id',
        outboxEntityType: PlanningOutboxQueue.plansEntityType,
        enqueue: (r) async {
      final plan = await plans.getByIdIncludingDeleted(r['id']! as String);
      return plan != null && await _planning.enqueuePlan(opOf(r), plan);
    });
    each('cards', pe, 'entity_id',
        outboxEntityType: PlanningOutboxQueue.cardsEntityType,
        // Account-less cards are local-only while the cards cloud v2 flag is off.
        extraWhere: kUserCardsCloudV2 ? '' : 'AND account_id IS NOT NULL',
        enqueue: (r) async {
      final row = await one('cards', r['id']);
      return row != null &&
          await _planning.enqueueCard(opOf(r), cardFromRow(row));
    });
    each('categories', pe, 'entity_id',
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
    each('user_settings', pe, 'entity_id',
        outboxEntityType: PlanningOutboxQueue.settingsEntityType,
        hasDeletedAt: false, enqueue: (r) async {
      final row = await one('user_settings', r['id']);
      return row != null &&
          await _planning.enqueueSettings(
              PlanningSyncOperation.update, userSettingsFromRow(row));
    });

    // Children (immutable). Deleted -> delete; live -> idempotent create.
    each('bill_payments', pe, 'entity_id',
        outboxEntityType: PlanningOutboxQueue.billPaymentsEntityType,
        enqueue: (r) async {
      final payment = await bills.getPaymentIncludingDeleted(r['id']! as String);
      return payment != null &&
          await _planning.enqueueBillPayment(
              r['deleted_at'] == null
                  ? PlanningSyncOperation.create
                  : PlanningSyncOperation.delete,
              payment);
    });
    each('goal_contributions', pe, 'entity_id',
        outboxEntityType: PlanningOutboxQueue.goalContributionsEntityType,
        enqueue: (r) async {
      final row = await _db.customSelect(
        'SELECT c.*, g.currency AS goal_currency FROM goal_contributions c '
        'JOIN goals g ON g.id = c.goal_id '
        'WHERE c.id = ${sqlString(r['id']! as String)} LIMIT 1;',
      ).getSingleOrNull();
      return row != null &&
          await _planning.enqueueGoalContribution(
            // D1: a tombstoned contribution is a delete (0116 endpoint).
            r['deleted_at'] == null
                ? PlanningSyncOperation.create
                : PlanningSyncOperation.delete,
            goalContributionFromRow(row, row.read<String>('goal_currency')),
          );
    });
    // Plan links have no `id`: key = '<plan_id>:<transaction_id>' (the outbox
    // entity id).
    each('plan_transaction_links', pe, 'entity_id',
        outboxEntityType: PlanningOutboxQueue.planLinksEntityType,
        idExpr: "plan_id || ':' || transaction_id",
        extraCols: ', plan_id, transaction_id, created_at',
        enqueue: (r) async {
      return _planning.enqueuePlanLink(
        r['deleted_at'] == null
            ? PlanningSyncOperation.create
            : PlanningSyncOperation.delete,
        planId: r['plan_id']! as String,
        transactionId: r['transaction_id']! as String,
        createdAt: dateTimeFromSql(r['created_at']! as String),
      );
    });

    final quota = (limit / sources.length).ceil().clamp(1, limit);
    for (final src in sources) {
      await drain(src, quota);
    }
    for (final src in sources) {
      await drain(src, limit);
    }
    return recorded;
  }

  static const _pageSize = 100;
}

class _Source {
  _Source({required this.domain, required this.enqueue, required this.sql});

  final SyncDomain domain;
  final Future<bool> Function(Map<String, Object?> row) enqueue;
  final String Function(String lastId, int pageSize) sql;
  String lastId = '';
  bool exhausted = false;
  bool failureReported = false;
}
