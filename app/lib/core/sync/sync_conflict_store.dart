import 'dart:convert';

import '../../data/db/app_database.dart';
import '../../data/db/sql_value_codec.dart';
import '../utils/id_generator.dart';
import 'conflict_policy.dart';

/// WP-5 — what kind of collision a durable conflict records.
enum SyncConflictKind {
  /// Local edit vs a cloud version that moved past the edit's base.
  update,

  /// Local delete vs a cloud version that moved past the delete's base.
  delete,

  /// Local edit vs a cloud tombstone. A tombstone is never un-deleted.
  tombstone,

  /// Insert-if-absent found the same identity with different client fields.
  create,
}

/// One durable `sync_conflicts` row. [mine] is the local record as the user
/// left it, [theirs] the cloud row (server vocabulary), [base] the version the
/// edit started from when it is known.
class SyncConflictRecord {
  const SyncConflictRecord({
    required this.id,
    required this.entityType,
    required this.localId,
    required this.kind,
    this.serverId,
    this.base,
    this.mine,
    this.theirs,
    this.theirsRevision,
    this.operationId,
  });

  final String id;
  final String entityType;
  final String localId;
  final SyncConflictKind kind;
  final String? serverId;
  final Map<String, dynamic>? base;
  final Map<String, dynamic>? mine;
  final Map<String, dynamic>? theirs;
  final int? theirsRevision;
  final String? operationId;
}

/// Durable conflict store. Writing a conflict also flags the entity
/// (`sync_status = 'conflict'`) in the same local transaction, so a conflict
/// is never only in memory and never only a flag.
class SyncConflictStore {
  SyncConflictStore(this._db);

  final AppDatabase _db;

  /// Records (or refreshes) the single open conflict of an entity and flags the
  /// entity. The first [base] is kept when the record already exists.
  Future<void> flag({
    required String entityType,
    required String localId,
    required SyncConflictKind kind,
    String? serverId,
    Map<String, dynamic>? base,
    Map<String, dynamic>? mine,
    Map<String, dynamic>? theirs,
    int? theirsRevision,
    String? operationId,
  }) async {
    final policy = conflictPolicyFor(entityType);
    final now = sqlString(dateTimeToSql(DateTime.now().toUtc()));
    final mineSnapshot = mine ?? await localSnapshot(entityType, localId);
    String? j(Map<String, dynamic>? m) =>
        m == null ? null : jsonEncode(m, toEncodable: (o) => o.toString());
    await _db.transaction(() async {
      final open = await _db
          .customSelect(
            'SELECT id FROM sync_conflicts WHERE entity_type = '
            '${sqlString(entityType)} AND local_id = ${sqlString(localId)} '
            'AND resolved_at IS NULL LIMIT 1;',
          )
          .getSingleOrNull();
      if (open == null) {
        await _db.customStatement('''
          INSERT INTO sync_conflicts(
            id, entity_type, local_id, server_id, kind, base_json, mine_json,
            theirs_json, theirs_revision, operation_id, created_at, updated_at
          ) VALUES (
            ${sqlString(IdGenerator.next())}, ${sqlString(entityType)},
            ${sqlString(localId)}, ${sqlNullableString(serverId)},
            ${sqlString(kind.name)}, ${sqlNullableString(j(base))},
            ${sqlNullableString(j(mineSnapshot))},
            ${sqlNullableString(j(theirs))}, ${theirsRevision ?? 'NULL'},
            ${sqlNullableString(operationId)}, $now, $now);
        ''');
      } else {
        await _db.customStatement('''
          UPDATE sync_conflicts SET kind = ${sqlString(kind.name)},
            server_id = COALESCE(${sqlNullableString(serverId)}, server_id),
            base_json = COALESCE(base_json, ${sqlNullableString(j(base))}),
            mine_json = ${sqlNullableString(j(mineSnapshot))},
            theirs_json = ${sqlNullableString(j(theirs))},
            theirs_revision = ${theirsRevision ?? 'NULL'},
            operation_id = ${sqlNullableString(operationId)},
            updated_at = $now
          WHERE id = ${sqlString(open.read<String>('id'))};
        ''');
      }
      await _db.customStatement(
        "UPDATE ${policy.localTable} SET sync_status = 'conflict' "
        'WHERE id = ${sqlString(localId)};',
      );
    });
  }

  Future<List<SyncConflictRecord>> open() async {
    final rows = await _db
        .customSelect('SELECT * FROM sync_conflicts WHERE resolved_at IS NULL '
            'ORDER BY created_at, id;')
        .get();
    return rows.map(_fromRow).toList();
  }

  Future<SyncConflictRecord?> openFor(String entityType, String localId) async {
    final row = await _db
        .customSelect(
          'SELECT * FROM sync_conflicts WHERE entity_type = '
          '${sqlString(entityType)} AND local_id = ${sqlString(localId)} '
          'AND resolved_at IS NULL LIMIT 1;',
        )
        .getSingleOrNull();
    return row == null ? null : _fromRow(row);
  }

  Future<void> resolve(
      String entityType, String localId, String resolution) async {
    await _db.customStatement(
      'UPDATE sync_conflicts SET resolved_at = '
      '${sqlString(dateTimeToSql(DateTime.now().toUtc()))}, '
      'resolution = ${sqlString(resolution)} WHERE entity_type = '
      '${sqlString(entityType)} AND local_id = ${sqlString(localId)} '
      'AND resolved_at IS NULL;',
    );
  }

  /// The local record as it stands now (the user's version), as JSON-safe data.
  /// A transaction also carries its stable category key, which is what the
  /// cloud row stores.
  Future<Map<String, dynamic>?> localSnapshot(
      String entityType, String localId) async {
    final policy = conflictPolicyFor(entityType);
    final row = await _db
        .customSelect(
            'SELECT * FROM ${policy.localTable} WHERE id = ${sqlString(localId)} LIMIT 1;')
        .getSingleOrNull();
    if (row == null) return null;
    final data = Map<String, dynamic>.from(row.data);
    if (entityType == ConflictEntities.transaction &&
        data['category_id'] is String) {
      final cat = await _db
          .customSelect('SELECT key FROM categories WHERE id = '
              '${sqlString(data['category_id'] as String)} LIMIT 1;')
          .getSingleOrNull();
      data['category_key'] = cat?.readNullable<String>('key');
    }
    return data;
  }

  static SyncConflictRecord _fromRow(dynamic row) {
    Map<String, dynamic>? m(String c) {
      final s = row.readNullable<String>(c) as String?;
      return s == null ? null : (jsonDecode(s) as Map).cast<String, dynamic>();
    }

    return SyncConflictRecord(
      id: row.read<String>('id') as String,
      entityType: row.read<String>('entity_type') as String,
      localId: row.read<String>('local_id') as String,
      serverId: row.readNullable<String>('server_id') as String?,
      kind: SyncConflictKind.values
          .byName(row.read<String>('kind') as String),
      base: m('base_json'),
      mine: m('mine_json'),
      theirs: m('theirs_json'),
      theirsRevision: row.readNullable<int>('theirs_revision') as int?,
      operationId: row.readNullable<String>('operation_id') as String?,
    );
  }
}
