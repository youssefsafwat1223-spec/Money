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

  /// Lower-value / re-derivable — reported but not blocking.
  final int senderMappingsPending;
  final int notificationLogPending;

  /// Financially-meaningful, user-authored data the wipe would destroy. Drives
  /// the "block sign-out / require explicit discard" decision.
  int get pendingUserDataCount =>
      ledgerOutbox + planningOutbox + smartInboxPending + localOnlyCards;

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

  Future<UnsyncedInventory> collect() async {
    return UnsyncedInventory(
      ledgerOutbox: await _count('ledger_sync_outbox'),
      planningOutbox: await _count('planning_sync_outbox'),
      smartInboxPending: await _count('smart_inbox_items', 'pending_sync = 1'),
      localOnlyCards: await _localOnlyCardCount(),
      senderMappingsPending:
          await _count('sender_bank_mappings', "source != 'remote'"),
      notificationLogPending: await _count('notification_log_events'),
    );
  }
}
