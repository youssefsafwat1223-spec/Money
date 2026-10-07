import 'dart:convert';

import '../../data/db/app_database.dart';
import '../../data/db/sql_value_codec.dart';
import '../utils/id_generator.dart';
import 'conflict_fields.dart';
import 'conflict_policy.dart';
import 'sync_conflict_store.dart';

/// A row stuck in `sync_status='conflict'` — a genuine two-device edit collision
/// — surfaced for the user to resolve.
class SyncConflict {
  const SyncConflict({
    required this.entityType,
    required this.localId,
    required this.label,
    this.kind,
    this.fields = const [],
    this.canKeepMine = true,
  });

  final String entityType;
  final String localId;
  final String label;

  /// WP-5: what collided (null for a legacy flagged conflict with no durable
  /// record — it shows no differences).
  final SyncConflictKind? kind;

  /// WP-5 / SYNC-Q5: the meaningful field differences (empty for deletes).
  final List<ConflictFieldDiff> fields;

  /// False where "keep mine" has no safe server operation (a cloud tombstone is
  /// never un-deleted, so only a transaction can be kept, as a new record).
  final bool canKeepMine;
}

/// Re-enqueues the CURRENT local state of one row as an update, so the next push
/// carries the user's edit. Entity-specific (it rebuilds the outbox payload via
/// the typed repository + queue), so it is injected per entity by DI.
typedef ConflictReEnqueue = Future<void> Function(String localId);

/// Keep-mine against a cloud TOMBSTONE: the deleted cloud row is never
/// un-deleted, so the local record is re-created as a NEW record (new identity,
/// queued as a create). Injected per entity (transactions only).
typedef ConflictRestoreAsNew = Future<void> Function(String localId);

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
/// How keep-remote obtains and applies the CURRENT server row of one entity
/// type. [fetch] is consent/owner-gated by the pull service behind it and
/// throws when the server cannot be reached; [apply] is that same service's own
/// pull apply path (exact money decode, tombstones, base token).
class ConflictRemoteSync {
  const ConflictRemoteSync({required this.fetch, required this.apply});
  final Future<Map<String, dynamic>?> Function(String serverId) fetch;
  final Future<void> Function(Map<String, dynamic> row) apply;
}

class UniversalConflictResolver {
  UniversalConflictResolver({
    required AppDatabase db,
    required Map<String, ConflictReEnqueue> reEnqueue,
    ConflictBaseFetcher? baseFetcher,
    Map<String, ConflictRemoteSync> remoteSync = const {},
    Map<String, ConflictRestoreAsNew> restoreAsNew = const {},
  })  : _db = db,
        _store = SyncConflictStore(db),
        _restoreAsNew = restoreAsNew,
        _reEnqueue = reEnqueue,
        _baseFetcher = baseFetcher,
        _remoteSync = remoteSync;

  final Map<String, ConflictRemoteSync> _remoteSync;
  final Map<String, ConflictRestoreAsNew> _restoreAsNew;
  final SyncConflictStore _store;

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
        final localId = row.read<String>('id');
        final record = await _store.openFor(policy.entityType, localId);
        out.add(SyncConflict(
          entityType: policy.entityType,
          localId: localId,
          label: row.readNullable<String>('label') ?? localId,
          kind: record?.kind,
          fields: record == null || record.kind == SyncConflictKind.tombstone
              ? const []
              : diffConflictFields(
                  policy.entityType, record.mine, record.theirs),
          canKeepMine: record?.kind != SyncConflictKind.tombstone ||
              _restoreAsNew.containsKey(policy.entityType),
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
    final record = await _store.openFor(entityType, localId);

    // A cloud tombstone is never un-deleted: keep-mine re-creates the record as
    // a NEW one (transactions); other entities have no safe keep-mine.
    if (record?.kind == SyncConflictKind.tombstone) {
      final restore = _restoreAsNew[entityType];
      if (restore == null) return;
      await _db.transaction(() async {
        await restore(localId);
        await _removeOutbox(policy, localId);
        await _db.customStatement(
          "UPDATE ${policy.localTable} SET sync_status = 'synced', "
          "status = 'ignored' WHERE id = ${sqlString(localId)};",
        );
        await _store.resolve(entityType, localId, 'mine_as_new');
      });
      return;
    }

    // Rebase BEFORE re-enqueue: the payload captures the refreshed base token
    // (planning reads server_updated_at from the row; the ledger reads it from
    // the entity — both see the value written here). The durable record already
    // holds the cloud version, so no network is needed; a legacy flagged
    // conflict without a record falls back to the injected fetcher.
    final serverId = await _serverId(policy.localTable, localId);
    final stored = record?.theirs;
    if (stored != null && record!.theirsRevision != null) {
      final sets = <String>[
        'server_revision = ${record.theirsRevision}',
        if (stored['updated_at'] is String)
          'server_updated_at = ${sqlString(stored['updated_at'] as String)}',
      ];
      await _db.customStatement(
        'UPDATE ${policy.localTable} SET ${sets.join(', ')} '
        'WHERE id = ${sqlString(localId)};',
      );
    } else if (serverId != null && _baseFetcher != null) {
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
    await _store.resolve(entityType, localId, 'mine');
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

  /// Keep the remote edit. Returns true when the row now equals the server.
  ///
  /// The pull that raised the conflict already advanced its keyset cursor past
  /// the server row, so a later incremental pull would never bring it back and
  /// the device would silently keep its own value marked synced. Entities with
  /// a registered [ConflictRemoteSync] therefore FETCH the current server row by
  /// id and apply it through the pull's own apply path, atomically with dropping
  /// the queued local change. If the fetch or apply fails (offline, auth,
  /// consent off, row gone) NOTHING changes: the row stays in conflict so the
  /// user can retry, and false is returned.
  ///
  /// Entities without a registered sync keep the legacy behaviour (drop the
  /// queue, mark synced with the stale base; deterministic config only).
  Future<bool> resolveKeepRemote(String entityType, String localId) async {
    final policy = conflictPolicyFor(entityType);
    if (!policy.canConflict) return true;

    // D-8: a push of this entity is on the wire (durable in_flight_seq marker).
    // Dropping its outbox row / applying the remote now would race that push, so
    // change nothing and let the caller try again later.
    if (await _hasInFlightOutbox(policy, localId)) return false;

    final sync = _remoteSync[entityType];
    final serverId = await _serverId(policy.localTable, localId);
    if (sync == null || serverId == null) {
      await _removeOutbox(policy, localId);
      await _db.customStatement(
        "UPDATE ${policy.localTable} SET sync_status = 'synced' "
        'WHERE id = ${sqlString(localId)};',
      );
      await _store.resolve(entityType, localId, 'cloud');
      return true;
    }

    final Map<String, dynamic>? remote;
    try {
      remote = await sync.fetch(serverId);
    } catch (_) {
      return false;
    }
    if (remote == null) return false;

    try {
      await _db.transaction(() async {
        await _removeOutbox(policy, localId);
        // A null base forces the pull's apply path to write the remote fields.
        await _db.customStatement(
          "UPDATE ${policy.localTable} SET sync_status = 'synced', "
          'server_updated_at = NULL WHERE id = ${sqlString(localId)};',
        );
        await sync.apply(remote!);
        await _store.resolve(entityType, localId, 'cloud');
      });
      return true;
    } catch (_) {
      return false;
    }
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
        if (await resolveKeepRemote(policy.entityType, row.read<String>('id'))) {
          resolved++;
        }
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

  Future<bool> _hasInFlightOutbox(
      EntityConflictPolicy policy, String localId) async {
    final row = await _db
        .customSelect(
          switch (policy.outbox) {
            OutboxKind.ledger => 'SELECT 1 AS x FROM ledger_sync_outbox '
                'WHERE transaction_id = ${sqlString(localId)} '
                'AND in_flight_seq IS NOT NULL LIMIT 1;',
            OutboxKind.planning => 'SELECT 1 AS x FROM planning_sync_outbox '
                'WHERE entity_type = ${sqlString(policy.entityType)} '
                'AND entity_id = ${sqlString(localId)} '
                'AND in_flight_seq IS NOT NULL LIMIT 1;',
          },
        )
        .getSingleOrNull();
    return row != null;
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
