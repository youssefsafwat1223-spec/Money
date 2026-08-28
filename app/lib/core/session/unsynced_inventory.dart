import '../../data/db/app_database.dart';

/// MALI-053n/011: an authoritative snapshot of locally-pending user artifacts,
/// taken before a destructive sign-out so unsynced/local-only data is never
/// silently wiped. Counts every push outbox plus local-only (cloud-unsupported)
/// cards; also reports the lower-value diagnostic/re-derivable queues for
/// completeness, which are flushed best-effort but do NOT block sign-out.
class UnsyncedInventory {
  const UnsyncedInventory({
    required this.ledgerOutbox,
    required this.planningOutbox,
    required this.smartInboxPending,
    required this.localOnlyCards,
    required this.senderMappingsPending,
    required this.notificationLogPending,
    this.unprovenFinancialRows = 0,
    this.unresolvedConflicts = 0,
  });

  /// Pending ledger (transaction) push operations.
  final int ledgerOutbox;

  /// Pending planning push operations — accounts, budgets/goals/subscriptions/
  /// plans (parents) AND goal contributions / bill payments / plan links
  /// (children), which all queue through `planning_sync_outbox`.
  final int planningOutbox;
  final int smartInboxPending;

  /// Active, never-synced cards that the current cloud schema can't represent
  /// (unassigned or custom-designed) — would be lost on wipe.
  final int localOnlyCards;

  /// Audit H-3. Active financial rows with NO `server_id` that are ALSO not
  /// represented on any outbox — the legacy/never-uploaded class that the
  /// startup reconcile exists to fix. Counting outboxes alone missed them
  /// entirely: a row whose backfill failed has no outbox entry, so sign-out
  /// saw "nothing pending" and wiped the only copy.
  final int unprovenFinancialRows;

  /// Rows in `sync_status='conflict'` — a remote counterpart exists but
  /// disagrees, so the LOCAL copy is still authoritative and unproven. These
  /// are resolvable non-destructively via the keep-mine/keep-theirs picker.
  final int unresolvedConflicts;

  /// Lower-value / re-derivable — reported but not blocking.
  final int senderMappingsPending;
  final int notificationLogPending;

  /// Financially-meaningful, user-authored data the wipe would destroy. Drives
  /// the "block sign-out / require explicit discard" decision.
  ///
  /// The invariant: sign-out must not destroy locally-authoritative data whose
  /// remote persistence has not been POSITIVELY proven. An empty outbox is not
  /// proof — it is merely the absence of a queued intent.
  int get pendingUserDataCount =>
      ledgerOutbox +
      planningOutbox +
      smartInboxPending +
      localOnlyCards +
      unprovenFinancialRows +
      unresolvedConflicts;

  bool get hasPendingUserData => pendingUserDataCount > 0;

  int get total =>
      pendingUserDataCount + senderMappingsPending + notificationLogPending;

  static const empty = UnsyncedInventory(
    ledgerOutbox: 0,
    planningOutbox: 0,
    smartInboxPending: 0,
    localOnlyCards: 0,
    senderMappingsPending: 0,
    notificationLogPending: 0,
  );
}

/// Collects an [UnsyncedInventory] directly from Drift. The local-only card
/// count is injected so this stays decoupled from the card repository.
class UnsyncedInventoryService {
  UnsyncedInventoryService(
    this._db, {
    required Future<int> Function() localOnlyCardCount,
  }) : _localOnlyCardCount = localOnlyCardCount;

  final AppDatabase _db;
  final Future<int> Function() _localOnlyCardCount;

  Future<int> _count(String table, [String where = '']) async {
    final clause = where.isEmpty ? '' : ' WHERE $where';
    final row = await _db
        .customSelect('SELECT COUNT(*) AS n FROM $table$clause;')
        .getSingle();
    return row.read<int>('n');
  }

  /// Audit H-3. Active financial rows that carry no `server_id` and are not
  /// queued on an outbox. Mirrors `StartupSyncReconcileService
  /// .hasUnsyncedLocalData()` so the two cannot drift: whatever the reconcile
  /// considers still-pending is exactly what sign-out must not silently
  /// destroy. Children are included — losing a contribution or a bill payment
  /// is losing user-authored money.
  Future<int> _unprovenFinancialRows() async {
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
             AND t.id NOT IN (SELECT transaction_id FROM ledger_sync_outbox))
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
             AND p.id NOT IN (SELECT entity_id FROM planning_sync_outbox))
        +
        (SELECT COUNT(*) FROM goal_contributions gc
           WHERE gc.deleted_at IS NULL AND gc.server_id IS NULL
             AND gc.id NOT IN (SELECT entity_id FROM planning_sync_outbox))
        +
        (SELECT COUNT(*) FROM bill_payments bp
           WHERE bp.deleted_at IS NULL AND bp.server_id IS NULL
             AND bp.id NOT IN (SELECT entity_id FROM planning_sync_outbox)) AS n;
    ''').getSingle();
    return row.read<int>('n');
  }

  /// Rows the sync layer has flagged as a genuine local/remote divergence.
  /// Their local copy is authoritative-and-unproven until the user resolves it.
  Future<int> _unresolvedConflicts() async {
    var total = 0;
    for (final table in const [
      'transactions',
      'accounts',
      'budgets',
      'subscriptions',
      'goals',
      'plans',
      'bill_payments',
      'goal_contributions',
    ]) {
      total += await _count(table, "sync_status = 'conflict'");
    }
    return total;
  }

  Future<UnsyncedInventory> collect() async {
    return UnsyncedInventory(
      ledgerOutbox: await _count('ledger_sync_outbox'),
      planningOutbox: await _count('planning_sync_outbox'),
      smartInboxPending: await _count('smart_inbox_items', 'pending_sync = 1'),
      localOnlyCards: await _localOnlyCardCount(),
      unprovenFinancialRows: await _unprovenFinancialRows(),
      unresolvedConflicts: await _unresolvedConflicts(),
      senderMappingsPending:
          await _count('sender_bank_mappings', "source != 'remote'"),
      notificationLogPending: await _count('notification_log_events'),
    );
  }
}
