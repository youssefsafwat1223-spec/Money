import 'package:flutter/foundation.dart';

import '../../../core/backend/supabase_config.dart';
import '../../../data/db/app_database.dart';
import '../../../data/db/planning_cutover.dart';
import '../../capture/services/transactions_backfill_service.dart';
import 'accounts_backfill_service.dart';
import 'outbox_queue_factory.dart';
import 'planning_primary_backfill_service.dart';

enum ReconcileOutcome { skippedGuest, skippedNothingPending, ran, failed }

/// One idempotent reconcile of local financial data that never reached
/// Supabase — pre-existing rows (created before the outbox existed, e.g. the
/// migration-seeded default account), and any capture that landed in a
/// background isolate without a restored session (so its outbox enqueue was
/// skipped). Runs the existing, verified backfill chain:
///
///   Local Drift → Backfill (idempotent direct upsert) → Supabase → local rows
///   marked synced (backlog cleared) → normal outbox push/pull from here on.
///
/// Guarded to be cheap: when everything is already synced or queued,
/// [hasUnsyncedLocalData] returns false and this does no network work.
/// Covers accounts, transactions, AND planning entities (budgets/goals/
/// subscriptions/plans + their children): a planning row that never uploaded
/// would otherwise be permanently destroyed by the sign-out wipe. Duplicate
/// safety: accounts/planning key on (user_id, local_id) on every push path,
/// transactions skip outbox-queued rows, and planning children are backstopped
/// by the server's partial unique (user_id, local_id) index — a row the live
/// outbox already pushed simply matches (or errors and is skipped), never
/// duplicates.
class StartupSyncReconcileService {
  StartupSyncReconcileService({
    required AppDatabase db,
    Future<String?> Function()? getAuthUserId,
    // MALI-026 (B8-3 §12): threaded to the transactions backfill so a canonical
    // (v30) backfill pushes EXACT decimal strings, never JSON-number money.
    PlanningCutoverCoordinator coordinator =
        const SchemaV29PlanningCutoverCoordinator(),
  })  : _db = db,
        _getAuthUserId = getAuthUserId ?? currentSupabaseUserId,
        _coordinator = coordinator;

  final AppDatabase _db;
  final Future<String?> Function() _getAuthUserId;
  final PlanningCutoverCoordinator _coordinator;

  Future<ReconcileOutcome> run() async {
    if (!SupabaseConfig.isConfigured) return ReconcileOutcome.skippedGuest;
    final uid = await _getAuthUserId();
    if (uid == null) return ReconcileOutcome.skippedGuest;

    if (!await hasUnsyncedLocalData()) {
      return ReconcileOutcome.skippedNothingPending;
    }

    try {
      // Ordered: accounts must carry server_ids before transactions/planning
      // can resolve their server_account_id foreign references. All services
      // are idempotent (keyed on local_id / client_request_id) and the account
      // ones assert local-data ownership (no cross-account upload).
      await AccountsBackfillService(db: _db).run();
      await TransactionsBackfillService(db: _db, coordinator: _coordinator).run();
      // Planning entities too — otherwise budgets/goals/subscriptions/plans
      // created before sync (or with no session) stay local-only and are
      // permanently destroyed by the next sign-out wipe. Rows already queued
      // on the planning outbox may individually no-op/fail against the
      // server's (user_id, local_id) unique constraint — the outbox push owns
      // those; nothing duplicates.
      await PlanningPrimaryBackfillService(db: _db).run();
      if (kDebugMode) debugPrint('[Reconcile] backfill complete');
      return ReconcileOutcome.ran;
    } catch (error) {
      // Offline / transient failure — leave rows unsynced so the guard trips
      // again on the next sync cycle and retries.
      if (kDebugMode) debugPrint('[Reconcile] backfill deferred: $error');
      return ReconcileOutcome.failed;
    }
  }

  /// True when any account, transaction, or planning parent (budget/goal/
  /// subscription/plan) is neither synced nor already queued on its outbox
  /// (the outbox push owns queued rows). Public for testing the guard
  /// predicate directly.
  @visibleForTesting
  Future<bool> hasUnsyncedLocalData() async {
    final row = await _db.customSelect('''
      SELECT
        (SELECT COUNT(*) FROM accounts a
           WHERE a.deleted_at IS NULL AND a.server_id IS NULL
             AND a.id NOT IN (
               SELECT entity_id FROM planning_sync_outbox
               WHERE entity_type = 'account'))
        +
        (SELECT COUNT(*) FROM transactions t
           WHERE t.server_id IS NULL
             AND t.id NOT IN (
               SELECT transaction_id FROM ledger_sync_outbox))
        +
        (SELECT COUNT(*) FROM budgets b
           WHERE b.deleted_at IS NULL AND b.server_id IS NULL
             AND b.id NOT IN (SELECT entity_id FROM planning_sync_outbox))
        +
        (SELECT COUNT(*) FROM goals g
           WHERE g.deleted_at IS NULL AND g.server_id IS NULL
             AND g.id NOT IN (SELECT entity_id FROM planning_sync_outbox))
        +
        (SELECT COUNT(*) FROM subscriptions s
           WHERE s.deleted_at IS NULL AND s.server_id IS NULL
             AND s.id NOT IN (SELECT entity_id FROM planning_sync_outbox))
        +
        (SELECT COUNT(*) FROM plans p
           WHERE p.deleted_at IS NULL AND p.server_id IS NULL
             AND p.id NOT IN (SELECT entity_id FROM planning_sync_outbox)) AS n;
    ''').getSingle();
    return row.read<int>('n') > 0;
  }
}
