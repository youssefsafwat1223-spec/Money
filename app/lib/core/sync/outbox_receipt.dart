/// WP-5 — recognising our OWN earlier write when the pull meets it.
///
/// A push can land on the server and lose its ACK (crash, network). The next
/// pull then finds a row that "moved past our base" — but the mover is us. The
/// server stamps `last_op_id` with the operation id of the last RPC write, so a
/// row whose `last_op_id` is the queued operation's id (or one of its earlier
/// ids, remembered in `prior_op_ids`) is our own write, never a conflict.
library;

import 'dart:convert';

import '../../data/db/app_database.dart';
import '../../data/db/sql_value_codec.dart';
import '../../data/sync/sync_cursor.dart';
import 'outbox_operation_id.dart';

enum OwnOpResult {
  /// Not ours (or no receipt available): the caller decides (conflict).
  none,

  /// The queued operation IS the cloud's last write: outbox consumed, entity
  /// settled and given the cloud's identity/revision.
  settled,

  /// An EARLIER operation of this entity is the cloud's last write and a newer
  /// edit is still queued: its base was advanced to the cloud's revision; the
  /// edit stays pending.
  rebased,
}

/// [outboxWhere] selects the entity's outbox row (e.g. `transaction_id = '..'`).
Future<OwnOpResult> settleOwnOperation({
  required AppDatabase db,
  required String outboxTable,
  required String outboxWhere,
  required String localTable,
  required String localId,
  required Map<String, dynamic> serverRow,
}) async {
  final last = serverRow['last_op_id'] as String?;
  if (last == null) return OwnOpResult.none;
  final row = await db
      .customSelect('SELECT id, operation_id, payload_json FROM $outboxTable '
          'WHERE $outboxWhere LIMIT 1;')
      .getSingleOrNull();
  if (row == null) return OwnOpResult.none;

  final serverId = serverRow['id'] as String?;
  final updatedAt = canonicalServerTimestamp(serverRow['updated_at'] as String?);
  final revision = (serverRow['revision'] as num?)?.toInt();
  final now = sqlString(dateTimeToSql(DateTime.now().toUtc()));
  final proof = '${serverId == null ? '' : 'server_id = ${sqlString(serverId)}, '}'
      'server_updated_at = ${sqlNullableString(updatedAt)}, '
      '${revision == null ? '' : 'server_revision = $revision, '}'
      'synced_at = $now';

  if (row.readNullable<String>('operation_id') == last) {
    await db.transaction(() async {
      await db.customStatement(
          'DELETE FROM $outboxTable WHERE id = ${sqlString(row.read<String>('id'))};');
      await db.customStatement(
        "UPDATE $localTable SET $proof, sync_status = CASE WHEN sync_status = "
        "'conflict' THEN sync_status ELSE 'synced' END "
        'WHERE id = ${sqlString(localId)};',
      );
    });
    return OwnOpResult.settled;
  }

  final payload =
      (jsonDecode(row.read<String>('payload_json')) as Map).cast<String, dynamic>();
  if (!priorOpIdsOf(payload).contains(last)) return OwnOpResult.none;
  if (serverId != null) payload['server_id'] = serverId;
  if (updatedAt != null) payload['server_updated_at'] = updatedAt;
  if (revision != null) payload['server_revision'] = revision;
  await db.transaction(() async {
    await db.customStatement(
      'UPDATE $outboxTable SET payload_json = ${sqlString(jsonEncode(payload))}, '
      '${revision == null ? '' : 'base_revision = $revision, '}'
      'in_flight_seq = NULL WHERE id = ${sqlString(row.read<String>('id'))};',
    );
    await db.customStatement(
        'UPDATE $localTable SET $proof WHERE id = ${sqlString(localId)};');
  });
  return OwnOpResult.rebased;
}
