import '../../data/db/app_database.dart';
import '../../data/db/sql_value_codec.dart';
import 'conflict_policy.dart';

/// A row stuck in `sync_status='conflict'` — a genuine two-device edit collision
/// — surfaced for the user to resolve.
class SyncConflict {
  const SyncConflict({
    required this.entityType,
    required this.localId,
    required this.label,
  });

  final String entityType;
  final String localId;
  final String label;
}

/// Re-enqueues the CURRENT local state of one row as an update, so the next push
/// carries the user's edit. Entity-specific (it rebuilds the outbox payload via
/// the typed repository + queue), so it is injected per entity by DI.
typedef ConflictReEnqueue = Future<void> Function(String localId);

/// Fetches the current server base token (`updated_at`) for a known server row,
/// used to rebase a kept-local edit. Injected so the resolver stays free of any
/// direct network dependency (and is trivially fakeable in tests).
typedef ConflictBaseFetcher = Future<String?> Function(
  String remoteTable,
  String serverId,
);

/// MALI-022 / MALI-057n — the universal, policy-driven conflict resolver.
///
/// Replaces the planning-only resolver. It honours [kConflictPolicies] so every
/// one of the twelve synced entities has a defined way out of a conflict:
///
///   • interactive entities (financial data) are listed for the user, who picks
///     keep-mine ([resolveKeepLocal]) or keep-theirs ([resolveKeepRemote]);
///   • deterministic entities (low-stakes config) are auto-resolved in favour of
///     the server copy by [autoResolveDeterministic];
///   • append-only children never reach a conflict state, so they are ignored.
///
/// The resolution mechanics are generic (they operate on the shared sync columns
/// and the two outboxes); only the keep-local re-enqueue is entity-specific and
/// supplied through [reEnqueue].
class UniversalConflictResolver {
  UniversalConflictResolver({
    required AppDatabase db,
    required Map<String, ConflictReEnqueue> reEnqueue,
    ConflictBaseFetcher? baseFetcher,
  })  : _db = db,
        _reEnqueue = reEnqueue,
        _baseFetcher = baseFetcher;

  final AppDatabase _db;
  final Map<String, ConflictReEnqueue> _reEnqueue;
  final ConflictBaseFetcher? _baseFetcher;

  /// Every unresolved conflict on an INTERACTIVE entity (drives the picker UI).
  Future<List<SyncConflict>> listConflicts() async {
    final out = <SyncConflict>[];
    for (final policy in interactiveConflictPolicies) {
      final label = policy.labelSql ?? 'id';
      final deletedClause = policy.softDelete ? ' AND deleted_at IS NULL' : '';
      final rows = await _db
          .customSelect(
            'SELECT id, ($label) AS label FROM ${policy.localTable} '
            "WHERE sync_status = 'conflict'$deletedClause "
            'ORDER BY id;',
          )
          .get();
      for (final row in rows) {
        out.add(SyncConflict(
          entityType: policy.entityType,
          localId: row.read<String>('id'),
          label: row.readNullable<String>('label') ?? row.read<String>('id'),
        ));
      }
    }
    return out;
  }

  /// Keep the local edit: rebase to the current server version and re-enqueue an
  /// update, so the next push cleanly overwrites the remote row. The re-enqueue
  /// coalesces into any pending outbox row for the same entity (Batch 2), so
  /// resolving twice can't queue two writes.
  Future<void> resolveKeepLocal(String entityType, String localId) async {
    final policy = conflictPolicyFor(entityType);
    if (!policy.canConflict) return;

    // Rebase BEFORE re-enqueue: the payload captures the refreshed base token
    // (planning reads server_updated_at from the row; the ledger reads it from
    // the entity — both see the value written here).
    final serverId = await _serverId(policy.localTable, localId);
    if (serverId != null && _baseFetcher != null) {
      final current = await _baseFetcher(policy.remoteTable, serverId);
      if (current != null) {
        await _db.customStatement(
          'UPDATE ${policy.localTable} '
          'SET server_updated_at = ${sqlString(current)} '
          'WHERE id = ${sqlString(localId)};',
        );
      }
    }

    final reEnqueue = _reEnqueue[entityType];
    if (reEnqueue != null) await reEnqueue(localId);

    await _db.customStatement(
      "UPDATE ${policy.localTable} SET sync_status = 'pending' "
      'WHERE id = ${sqlString(localId)};',
    );
  }

  /// Keep the remote edit: drop any queued local change and mark the row synced
  /// with its stale base, so the next pull (which sees the server moved past
  /// that base) overwrites the local row with the server's version. This is also
  /// the deterministic prefer-remote outcome.
  Future<void> resolveKeepRemote(String entityType, String localId) async {
    final policy = conflictPolicyFor(entityType);
    if (!policy.canConflict) return;
    await _removeOutbox(policy, localId);
    await _db.customStatement(
      "UPDATE ${policy.localTable} SET sync_status = 'synced' "
      'WHERE id = ${sqlString(localId)};',
    );
  }

  /// Auto-resolve every conflict on a DETERMINISTIC entity in favour of the
  /// server copy. Returns how many rows were resolved. Called after a sync pass
  /// so low-stakes config never sits stuck in `conflict` awaiting a prompt that
  /// will never come.
  Future<int> autoResolveDeterministic() async {
    var resolved = 0;
    for (final policy in deterministicConflictPolicies) {
      final rows = await _db
          .customSelect(
            'SELECT id FROM ${policy.localTable} '
            "WHERE sync_status = 'conflict';",
          )
          .get();
      for (final row in rows) {
        await resolveKeepRemote(policy.entityType, row.read<String>('id'));
        resolved++;
      }
    }
    return resolved;
  }

  Future<String?> _serverId(String table, String localId) async {
    final row = await _db
        .customSelect(
          'SELECT server_id FROM $table WHERE id = ${sqlString(localId)} LIMIT 1;',
        )
        .getSingleOrNull();
    return row?.readNullable<String>('server_id');
  }

  Future<void> _removeOutbox(EntityConflictPolicy policy, String localId) async {
    switch (policy.outbox) {
      case OutboxKind.ledger:
        await _db.customStatement(
          'DELETE FROM ledger_sync_outbox '
          'WHERE transaction_id = ${sqlString(localId)};',
        );
      case OutboxKind.planning:
        await _db.customStatement(
          'DELETE FROM planning_sync_outbox '
          'WHERE entity_type = ${sqlString(policy.entityType)} '
          'AND entity_id = ${sqlString(localId)};',
        );
    }
  }
}
