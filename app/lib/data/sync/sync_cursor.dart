import '../db/app_database.dart';
import '../db/sql_value_codec.dart';

const syncCursorEpoch = '1970-01-01T00:00:00.000Z';

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
