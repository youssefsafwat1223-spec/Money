import 'package:flutter/foundation.dart';

import '../../../core/backend/supabase_config.dart';
import '../../../data/db/app_database.dart';
import '../../../data/db/planning_cutover.dart';
import '../../../data/sync/exact_transport_capability.dart';
import '../../capture/services/transactions_backfill_service.dart';
import 'accounts_backfill_service.dart';
import 'outbox_queue_factory.dart';
import 'planning_primary_backfill_service.dart';

/// Audit **H-1**. `ran` used to mean only "no exception escaped" — the three
/// backfill reports were DISCARDED, and the planning service records phase
/// failures in its report rather than throwing. A wholly failed backfill was
/// therefore indistinguishable from a clean one: the row stayed
/// `server_id IS NULL` with no outbox entry, invisible to the pre-sign-out
/// inventory, and sign-out then destroyed the only copy.
///
/// `ran` now means **every row is positively proven persisted**. Anything less
/// is [partial] or [failed], and neither may be treated as success.
enum ReconcileOutcome {
  skippedGuest,
  skippedNothingPending,

  /// Complete and clean — no failed phase, no unresolved money mismatch.
  ran,

  /// Some work succeeded and some did not. Deliberately distinct from [failed]:
  /// collapsing them would lose the fact that part of the data IS durable, and
  /// collapsing partial into [ran] is the defect this enum value exists to
  /// prevent.
  partial,

  /// Nothing could be reconciled (threw before or through the chain).
  failed,

  /// Audit H-4. The database is CANONICAL but the exact-money PUSH transport is
  /// not verified, so a backfill would send exact decimal strings over an
  /// unproven transport — the case [shouldParkExactMoneyWrite] exists to
  /// prevent. Nothing was attempted; local rows keep their unproven state and
  /// stay visible to the pre-sign-out inventory. Retried once the capability is
  /// positively proven.
  blockedUnverifiedTransport,
}

extension ReconcileOutcomeX on ReconcileOutcome {
  /// The ONLY states in which local data may be considered remotely durable.
  /// Anything else must keep the local copy and stay visible to sign-out.
  ///
  /// This exists because `blocked` is a *successful return*, and a caller that
  /// checks `!= failed` would read it as success and be entitled to discard the
  /// local copy. Naming the safe set positively removes that reading.
  bool get isProvenComplete =>
      this == ReconcileOutcome.ran ||
      this == ReconcileOutcome.skippedNothingPending;

  /// Whether another attempt should be made once conditions change.
  bool get shouldRetry =>
      this == ReconcileOutcome.failed ||
      this == ReconcileOutcome.partial ||
      this == ReconcileOutcome.blockedUnverifiedTransport;
}

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
    // Audit H-4: the backfills are a PUSH path that serializes canonical money
    // as exact decimal strings, so they must obey the same transport authority
    // as every other push. Defaults to `unknown` — a caller that forgets it
    // fails CLOSED rather than pushing over an unproven transport.
    ExactTransportCapability Function() pushCapability =
        _unknownPushCapability,
  })  : _db = db,
        _getAuthUserId = getAuthUserId ?? currentSupabaseUserId,
        _coordinator = coordinator,
        _pushCapability = pushCapability;

  static ExactTransportCapability _unknownPushCapability() =>
      ExactTransportCapability.unknown;

  final AppDatabase _db;
  final Future<String?> Function() _getAuthUserId;
  final PlanningCutoverCoordinator _coordinator;
  final ExactTransportCapability Function() _pushCapability;

  Future<ReconcileOutcome> run() async {
    if (!SupabaseConfig.isConfigured) return ReconcileOutcome.skippedGuest;
    final uid = await _getAuthUserId();
    if (uid == null) return ReconcileOutcome.skippedGuest;

    if (!await hasUnsyncedLocalData()) {
      return ReconcileOutcome.skippedNothingPending;
    }

    // Audit H-4. A canonical backfill serializes money as an EXACT decimal
    // string; sending that over an unverified transport risks silent
    // server-side coercion the client cannot detect afterwards. This is the
    // identical predicate the outbox push services already honour — the
    // backfills bypassed it entirely, which would let an unauthorised transport
    // mark rows `synced` and report `ran`.
    if (shouldParkExactMoneyWrite(
      cutoverState: _coordinator.state(),
      pushCapability: _pushCapability(),
    )) {
      if (kDebugMode) {
        debugPrint('[Reconcile] parked: exact push transport unverified');
      }
      return ReconcileOutcome.blockedUnverifiedTransport;
    }

    try {
      // Ordered: accounts must carry server_ids before transactions/planning
      // can resolve their server_account_id foreign references. All services
      // are idempotent (keyed on local_id / client_request_id) and the account
      // ones assert local-data ownership (no cross-account upload).
      // Audit H-1: these reports are the ONLY evidence of what actually
      // persisted. Discarding them is what converted uncertainty into success.
      final accounts =
          await AccountsBackfillService(db: _db, coordinator: _coordinator)
              .run();
      final transactions =
          await TransactionsBackfillService(db: _db, coordinator: _coordinator)
              .run();
      // Planning entities too — otherwise budgets/goals/subscriptions/plans
      // created before sync (or with no session) stay local-only and are
      // permanently destroyed by the next sign-out wipe. Rows already queued
      // on the planning outbox may individually no-op/fail against the
      // server's (user_id, local_id) unique constraint — the outbox push owns
      // those; nothing duplicates.
      final planning = await PlanningPrimaryBackfillService(
              db: _db, coordinator: _coordinator)
          .run();

      // Any unresolved item ⇒ NOT proven. The affected rows keep their
      // local-only / conflict state, so `hasUnsyncedLocalData()` still sees
      // them, the sign-out inventory still counts them, and the next cycle
      // retries — every backfill is idempotent on (user_id, local_id).
      final unresolved = accounts.mismatchedLocalIds.length +
          transactions.mismatchedLocalIds.length +
          transactions.unresolvedAccountLocalIds.length +
          planning.failures.length +
          planning.mismatched.length +
          (accounts.defaultResolved ? 0 : 1);
      if (unresolved > 0) {
        if (kDebugMode) {
          debugPrint('[Reconcile] incomplete: $unresolved unresolved item(s)');
        }
        return ReconcileOutcome.partial;
      }

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
