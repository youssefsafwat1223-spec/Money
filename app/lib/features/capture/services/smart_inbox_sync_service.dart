import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/backend/supabase_config.dart';
import '../../../core/utils/id_generator.dart';
import '../../../data/db/app_database.dart';
import '../../../data/db/sql_value_codec.dart';

class SmartInboxSyncResult {
  const SmartInboxSyncResult({
    this.imported = 0,
    this.updated = 0,
    this.tombstoned = 0,
  });

  final int imported;
  final int updated;
  final int tombstoned;
}

/// Injectable remote source — real impl calls Supabase; test impl returns
/// fixture rows without network access.
abstract class SmartInboxRemoteSource {
  Future<List<Map<String, dynamic>>> fetchActiveRows({int limit});
  Future<List<Map<String, dynamic>>> fetchTombstones({int limit});
}

class SupabaseSmartInboxRemoteSource implements SmartInboxRemoteSource {
  const SupabaseSmartInboxRemoteSource();

  @override
  Future<List<Map<String, dynamic>>> fetchActiveRows({int limit = 200}) async {
    final response = await Supabase.instance.client
        .from('user_smart_inbox')
        .select()
        .isFilter('deleted_at', null)
        .order('created_at', ascending: false)
        .limit(limit);
    return (response as List).cast<Map<String, dynamic>>();
  }

  @override
  Future<List<Map<String, dynamic>>> fetchTombstones({int limit = 200}) async {
    final response = await Supabase.instance.client
        .from('user_smart_inbox')
        .select('id, deleted_at')
        .not('deleted_at', 'is', null)
        .order('updated_at', ascending: false)
        .limit(limit);
    return (response as List).cast<Map<String, dynamic>>();
  }
}

// The five types the app understands. Unknown types from future server
// schema additions are silently skipped so forward compatibility is free.
const _knownTypes = {
  'needs_review',
  'suspicious_duplicate',
  'low_confidence',
  'budget_warning',
  'insight',
};

class SmartInboxSyncService {
  SmartInboxSyncService({
    required AppDatabase db,
    required bool Function() isPullEnabled,
    SmartInboxRemoteSource? remoteSource,
    Future<String?> Function()? getAuthUserId,
  })  : _db = db,
        _isPullEnabled = isPullEnabled,
        _remoteSource = remoteSource ?? const SupabaseSmartInboxRemoteSource(),
        _getAuthUserId = getAuthUserId ?? _defaultGetAuthUserId;

  static Future<String?> _defaultGetAuthUserId() async {
    if (!SupabaseConfig.isConfigured) return null;
    try {
      return Supabase.instance.client.auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  final AppDatabase _db;
  final bool Function() _isPullEnabled;
  final SmartInboxRemoteSource _remoteSource;
  final Future<String?> Function() _getAuthUserId;

  Future<SmartInboxSyncResult> pull() async {
    if (!_isPullEnabled()) return const SmartInboxSyncResult();

    final userId = await _getAuthUserId();
    if (userId == null) return const SmartInboxSyncResult();

    int imported = 0;
    int updated = 0;
    int tombstoned = 0;

    try {
      final rows = await _remoteSource.fetchActiveRows();
      for (final row in rows) {
        try {
          final outcome = await _processRow(row);
          switch (outcome) {
            case _RowOutcome.imported:
              imported++;
            case _RowOutcome.updated:
              updated++;
            case _RowOutcome.skipped:
              break;
          }
        } catch (e) {
          if (kDebugMode) debugPrint('[SmartInboxSync] row error: $e');
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[SmartInboxSync] fetch error: $e');
    }

    try {
      final tombstoneRows = await _remoteSource.fetchTombstones();
      for (final row in tombstoneRows) {
        try {
          if (await _processTombstone(row)) tombstoned++;
        } catch (e) {
          if (kDebugMode) debugPrint('[SmartInboxSync] tombstone error: $e');
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[SmartInboxSync] tombstone fetch error: $e');
    }

    if (kDebugMode) {
      debugPrint(
        '[SmartInboxSync] done: imported=$imported updated=$updated '
        'tombstoned=$tombstoned',
      );
    }
    return SmartInboxSyncResult(
      imported: imported,
      updated: updated,
      tombstoned: tombstoned,
    );
  }

  Future<_RowOutcome> _processRow(Map<String, dynamic> row) async {
    final serverId = row['id'] as String?;
    if (serverId == null) return _RowOutcome.skipped;

    final type = row['type'] as String? ?? '';
    if (!_knownTypes.contains(type)) return _RowOutcome.skipped;

    final title = row['title'] as String?;
    if (title == null) return _RowOutcome.skipped;

    final serverUpdatedAt = row['updated_at'] as String?;
    final now = dateTimeToSql(DateTime.now().toUtc());

    final existing = await _db
        .customSelect(
          'SELECT id, server_updated_at, dismissed_locally '
          'FROM smart_inbox_items '
          'WHERE server_id = ${sqlString(serverId)} LIMIT 1;',
        )
        .getSingleOrNull();

    if (existing != null) {
      // Locally dismissed items are not overwritten — user intent wins.
      if (existing.read<int>('dismissed_locally') == 1) {
        return _RowOutcome.skipped;
      }

      // Update only if the server row is newer than what we last synced.
      final localTs = existing.readNullable<String>('server_updated_at');
      final localKnown = localTs != null ? DateTime.tryParse(localTs) : null;
      final serverTs =
          serverUpdatedAt != null ? DateTime.tryParse(serverUpdatedAt) : null;

      if (localKnown != null &&
          serverTs != null &&
          !serverTs.isAfter(localKnown)) {
        return _RowOutcome.skipped;
      }

      await _db.customStatement('''
        UPDATE smart_inbox_items
        SET title = ${sqlString(title)},
            body = ${sqlNullableString(row['body'] as String?)},
            status = ${sqlString(row['status'] as String? ?? 'open')},
            confidence = ${row['confidence'] != null ? (row['confidence'] as num).toDouble() : 'NULL'},
            metadata_json = ${sqlString(jsonEncode(row['metadata'] ?? {}))},
            server_updated_at = ${sqlNullableString(serverUpdatedAt)},
            synced_at = ${sqlString(now)},
            updated_at = ${sqlString(now)}
        WHERE server_id = ${sqlString(serverId)};
      ''');
      return _RowOutcome.updated;
    }

    // New row — insert.
    final id = IdGenerator.next();
    final serverCreatedAt = row['created_at'] as String? ?? now;

    await _db.customStatement('''
      INSERT OR IGNORE INTO smart_inbox_items(
        id, server_id, transaction_id, payload_id,
        type, title, body, status, confidence, metadata_json,
        server_created_at, server_updated_at, synced_at,
        dismissed_locally, created_at, updated_at
      ) VALUES (
        ${sqlString(id)},
        ${sqlString(serverId)},
        ${sqlNullableString(row['transaction_id'] as String?)},
        ${sqlNullableString(row['payload_id'] as String?)},
        ${sqlString(type)},
        ${sqlString(title)},
        ${sqlNullableString(row['body'] as String?)},
        ${sqlString(row['status'] as String? ?? 'open')},
        ${row['confidence'] != null ? (row['confidence'] as num).toDouble() : 'NULL'},
        ${sqlString(jsonEncode(row['metadata'] ?? {}))},
        ${sqlString(serverCreatedAt)},
        ${sqlNullableString(serverUpdatedAt)},
        ${sqlString(now)},
        0,
        ${sqlString(now)},
        ${sqlString(now)}
      );
    ''');
    return _RowOutcome.imported;
  }

  Future<bool> _processTombstone(Map<String, dynamic> row) async {
    final serverId = row['id'] as String?;
    if (serverId == null) return false;

    final now = dateTimeToSql(DateTime.now().toUtc());
    final existing = await _db
        .customSelect(
          'SELECT id, status FROM smart_inbox_items '
          'WHERE server_id = ${sqlString(serverId)} LIMIT 1;',
        )
        .getSingleOrNull();
    if (existing == null) return false;

    if (existing.readNullable<String>('status') == 'dismissed') return false;

    await _db.customStatement('''
      UPDATE smart_inbox_items
      SET status = 'dismissed',
          updated_at = ${sqlString(now)}
      WHERE server_id = ${sqlString(serverId)};
    ''');
    return true;
  }
}

enum _RowOutcome { imported, updated, skipped }
