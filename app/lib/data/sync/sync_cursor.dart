import '../db/app_database.dart';
import '../db/sql_value_codec.dart';

const syncCursorEpoch = '1970-01-01T00:00:00.000Z';

/// Completion boundary of one pull pass. Batch-3: the legacy financial-cache
/// reconciler may only clear a dirty marker on [completed] — a pull that
/// [deferred] (feature/auth unavailable) or [failed] (network/page error, a
/// partial pass) must leave the marker set. "No exception thrown" is NOT
/// completion, because a pull swallows errors and returns a partial result.
enum SyncPullStatus {
  /// The paginated pull reached server EOF and its merge committed.
  completed,

  /// Not attempted this session (feature disabled / no authenticated user).
  /// The persisted cursor was not touched.
  deferred,

  /// Attempted but did not reach EOF (network/page/parse error) — partial.
  failed,
}

/// Default admission predicate for a normal (non-reconciliation) pull — always
/// admitted. Batch-3: a reconciliation-triggered full pull instead passes a real
/// admission-generation guard so an owner change (sign-out / relogin) mid-pull
/// stops it at the next page boundary.
bool alwaysAdmitted() => true;

/// Thrown inside a pull's page transaction when admission is lost before the
/// cursor is persisted — rolls back that page (applied rows AND cursor advance)
/// atomically so a stale generation neither applies data nor moves the cursor.
class ReconcilePullCancelled implements Exception {
  const ReconcilePullCancelled();

  @override
  String toString() => 'ReconcilePullCancelled';
}

/// مفتاح pagination حصري مرتب حسب `(updated_at, id)`.
class SyncCursor {
  const SyncCursor({
    required this.updatedAt,
    required this.id,
  });

  const SyncCursor.epoch()
      : updatedAt = syncCursorEpoch,
        id = '';

  final String updatedAt;
  final String id;

  factory SyncCursor.fromServerRow(Map<String, dynamic> row) {
    final id = row['id'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('Pull row is missing a server id');
    }
    return SyncCursor(
      updatedAt: normalizeCursorTimestamp(row['updated_at']),
      id: id,
    );
  }
}

/// The ONE canonical form of a server `updated_at` base token: the UTC instant
/// rendered by Dart's ISO-8601 formatter (deterministic per instant, microseconds
/// preserved). `Z` vs `+00:00` and `.000` vs `.000000` spellings of one instant
/// collapse to one string, so token equality is instant equality at every store
/// and compare site (a lossy ms truncation would break the server-side guard).
/// null/empty -> null (unknown base); an unparseable value is kept verbatim so it
/// still compares by equality instead of being silently dropped.
String? canonicalServerTimestamp(String? value) {
  if (value == null || value.isEmpty) return null;
  return DateTime.tryParse(value)?.toUtc().toIso8601String() ?? value;
}

/// كل أعمدة الترتيب الحالية NOT NULL في Supabase. تبقى قيمة epoch هنا حماية
/// دفاعية لصف قديم/fixture ناقص، وتمنع تخزين cursor فارغ غير قابل للمقارنة.
String normalizeCursorTimestamp(Object? value) {
  if (value is! String || value.isEmpty) return syncCursorEpoch;
  final parsed = DateTime.tryParse(value);
  return parsed?.toUtc().toIso8601String() ?? value;
}

Future<SyncCursor> readSyncCursor(AppDatabase db, String entity) async {
  final row = await db
      .customSelect(
        'SELECT last_updated_at, last_id FROM sync_cursors '
        'WHERE entity = ${sqlString(entity)} LIMIT 1;',
      )
      .getSingleOrNull();
  if (row == null) return const SyncCursor.epoch();
  return SyncCursor(
    updatedAt: row.read<String>('last_updated_at'),
    id: row.read<String>('last_id'),
  );
}

Future<void> writeSyncCursor(
  AppDatabase db,
  String entity,
  SyncCursor cursor,
) async {
  await db.customStatement('''
    INSERT INTO sync_cursors(entity, last_updated_at, last_id)
    VALUES (
      ${sqlString(entity)},
      ${sqlString(cursor.updatedAt)},
      ${sqlString(cursor.id)}
    )
    ON CONFLICT(entity) DO UPDATE SET
      last_updated_at = excluded.last_updated_at,
      last_id = excluded.last_id;
  ''');
}

/// WP-4 sequence-pull cursor. No schema change: it lives in the existing
/// `sync_cursors` table under `seq:<uid>:<entity>`, the integer `sync_seq`
/// rendered in `last_id` (`last_updated_at` stays at [syncCursorEpoch]). Keyed by
/// uid so a cursor can never be applied to another account's server stream, and
/// independent of the legacy timestamp cursor (manifest §8: separate cursors).
String seqCursorEntity(String uid, String entity) => 'seq:$uid:$entity';

/// 0 when absent (a full, idempotent page-through).
Future<int> readSeqCursor(AppDatabase db, String uid, String entity) async {
  final c = await readSyncCursor(db, seqCursorEntity(uid, entity));
  return int.tryParse(c.id) ?? 0;
}

Future<void> writeSeqCursor(
  AppDatabase db,
  String uid,
  String entity,
  int seq,
) =>
    writeSyncCursor(
      db,
      seqCursorEntity(uid, entity),
      SyncCursor(updatedAt: syncCursorEpoch, id: '$seq'),
    );

/// The server `user_sync_state.epoch` this replica last pulled under (read and
/// recorded only; rebootstrap on a mismatch is WP-7). Stored in `sync_cursors`
/// under `seq_epoch:<uid>`: epoch in `last_id`, reason in `last_updated_at`.
class RecordedSyncEpoch {
  const RecordedSyncEpoch(this.epoch, this.reason);
  final String epoch;
  final String reason;
}

Future<RecordedSyncEpoch?> readRecordedSyncEpoch(
  AppDatabase db,
  String uid,
) async {
  final key = 'seq_epoch:$uid';
  final row = await db
      .customSelect(
        'SELECT last_updated_at, last_id FROM sync_cursors '
        'WHERE entity = ${sqlString(key)} LIMIT 1;',
      )
      .getSingleOrNull();
  if (row == null) return null;
  return RecordedSyncEpoch(
      row.read<String>('last_id'), row.read<String>('last_updated_at'));
}

Future<void> writeRecordedSyncEpoch(
  AppDatabase db,
  String uid,
  String epoch,
  String? reason,
) =>
    writeSyncCursor(
      db,
      'seq_epoch:$uid',
      SyncCursor(updatedAt: reason ?? '', id: epoch),
    );
