import 'dart:convert';

import '../../data/db/app_database.dart';
import '../../data/db/sql_value_codec.dart';
import '../utils/id_generator.dart';
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

/// The current server base for a row: the `updated_at` token and, when the CAS
/// capability is active (0068 present), the server `revision`. Used to rebase a
/// kept-local edit so its next push cleanly wins.
class ConflictBase {
  const ConflictBase({this.updatedAt, this.revision});
  final String? updatedAt;
  final int? revision;
}

/// Fetches the current [ConflictBase] for a known server row. Injected so the
/// resolver stays free of any direct network dependency (and is fakeable).
typedef ConflictBaseFetcher = Future<ConflictBase?> Function(
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
      // Phase-9K: list EVERY conflict, including a row that is locally
      // soft-deleted (a stale-delete-vs-newer-update collision). Hiding those
      // (the old `deleted_at IS NULL` filter) made delete conflicts unresolvable.
      final rows = await _db
          .customSelect(
            'SELECT id, ($label) AS label FROM ${policy.localTable} '
            "WHERE sync_status = 'conflict' "
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
        final sets = <String>[];
        if (current.updatedAt != null) {
          sets.add('server_updated_at = ${sqlString(current.updatedAt!)}');
        }
        // Rebase the CAS base revision too (MALI-022 / 0068) so the re-enqueued
        // update's compare-and-set matches the current server row.
        if (current.revision != null) {
          sets.add('server_revision = ${current.revision}');
        }
        if (sets.isNotEmpty) {
          await _db.customStatement(
            'UPDATE ${policy.localTable} SET ${sets.join(', ')} '
            'WHERE id = ${sqlString(localId)};',
          );
        }
      }
    }

    // Phase-9K: if the local row is in its DELETED state, keeping "mine" means
    // re-applying the DELETE (rebased), not an update — the typed update
    // re-enqueue would resurrect the row (and the repos hide deleted rows, so it
    // would silently no-op). Re-enqueue a guarded tombstone instead.
    final deleted = await _db
        .customSelect(
          'SELECT 1 AS x FROM ${policy.localTable} '
          'WHERE id = ${sqlString(localId)} AND ${policy.deletedRowSql} LIMIT 1;',
        )
        .getSingleOrNull();
    if (deleted != null) {
      await _reEnqueueDelete(policy, localId, serverId);
    } else {
      final reEnqueue = _reEnqueue[entityType];
      if (reEnqueue != null) await reEnqueue(localId);
    }

    await _db.customStatement(
      "UPDATE ${policy.localTable} SET sync_status = 'pending' "
      'WHERE id = ${sqlString(localId)};',
    );
  }

  /// Phase-9K — re-enqueue a DELETE for a kept-local delete conflict, carrying
  /// the (just-rebased) base tokens so the guarded tombstone compare-and-sets
  /// against the current server row and cleanly wins.
  Future<void> _reEnqueueDelete(
    EntityConflictPolicy policy,
    String localId,
    String? serverId,
  ) async {
    final row = await _db
        .customSelect(
          'SELECT server_updated_at, server_revision FROM ${policy.localTable} '
          'WHERE id = ${sqlString(localId)} LIMIT 1;',
        )
        .getSingleOrNull();
    final payload = <String, dynamic>{
      'local_id': localId,
      if (serverId != null) 'server_id': serverId,
      if (row?.readNullable<String>('server_updated_at') != null)
        'server_updated_at': row!.readNullable<String>('server_updated_at'),
      if (row?.readNullable<int>('server_revision') != null)
        'server_revision': row!.readNullable<int>('server_revision'),
    };
    // The conflict already consumed the prior outbox row; clear any stray one so
    // the re-enqueued delete is the single pending mutation.
    await _removeOutbox(policy, localId);
    final now = dateTimeToSql(DateTime.now().toUtc());
    final id = IdGenerator.next();
    final json = jsonEncode(payload);
    switch (policy.outbox) {
      case OutboxKind.ledger:
        await _db.customStatement(
          'INSERT INTO ledger_sync_outbox(id, transaction_id, operation, '
          'payload_json, attempt_count, status, created_at, updated_at) VALUES ('
          '${sqlString(id)}, ${sqlString(localId)}, ${sqlString('delete')}, '
          '${sqlString(json)}, 0, ${sqlString('pending')}, ${sqlString(now)}, '
          '${sqlString(now)});',
        );
      case OutboxKind.planning:
        await _db.customStatement(
          'INSERT INTO planning_sync_outbox(id, entity_type, entity_id, '
          'operation, payload_json, attempt_count, status, created_at, '
          'updated_at) VALUES (${sqlString(id)}, ${sqlString(policy.entityType)}, '
          '${sqlString(localId)}, ${sqlString('delete')}, ${sqlString(json)}, 0, '
          '${sqlString('pending')}, ${sqlString(now)}, ${sqlString(now)});',
        );
    }
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

  Future<void> _removeOutbox(
      EntityConflictPolicy policy, String localId) async {
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
