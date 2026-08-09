import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/backend/supabase_config.dart';
import '../../../core/utils/id_generator.dart';
import '../../../data/db/app_database.dart';
import '../../../data/db/sql_value_codec.dart';
import '../../../data/sync/sync_cursor.dart';

class SmartInboxSyncResult {
  const SmartInboxSyncResult({
    this.imported = 0,
    this.updated = 0,
    this.tombstoned = 0,
    this.status = SyncPullStatus.deferred,
  });

  final int imported;
  final int updated;
  final int tombstoned;
  final SyncPullStatus status;
}

/// Injectable remote source — real impl calls Supabase; test impl returns
/// fixture rows without network access.
abstract class SmartInboxRemoteSource {
  Future<List<Map<String, dynamic>>> fetchRows({
    required SyncCursor after,
    int limit,
  });

  /// يدفع تغيير الحالة (رفض/معالجة) لصف الخادم المطابق للـ serverId.
  Future<void> pushStatus(String serverId, String status);
}

class SupabaseSmartInboxRemoteSource implements SmartInboxRemoteSource {
  const SupabaseSmartInboxRemoteSource();

  @override
  Future<void> pushStatus(String serverId, String status) async {
    await Supabase.instance.client
        .from('user_smart_inbox')
        .update({'status': status}).eq('id', serverId);
  }

  @override
  Future<List<Map<String, dynamic>>> fetchRows({
    required SyncCursor after,
    int limit = 200,
  }) async {
    final query = Supabase.instance.client.from('user_smart_inbox').select();
    final filtered = after.id.isEmpty
        ? query
        : query.or(
            'updated_at.gt.${after.updatedAt},'
            'and(updated_at.eq.${after.updatedAt},id.gt.${after.id})',
          );
    final response = await filtered
        .order('updated_at', ascending: true)
        .order('id', ascending: true)
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
    int pageSize = 200,
  })  : assert(pageSize > 0),
        _db = db,
        _isPullEnabled = isPullEnabled,
        _remoteSource = remoteSource ?? const SupabaseSmartInboxRemoteSource(),
        _pageSize = pageSize,
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
  final int _pageSize;

  static const _cursorKey = 'smart_inbox';

  /// S3 gap#1: يدفع تغييرات الحالة المحلية (رفض/معالجة) إلى الخادم.
  /// specialized لصندوق الوارد (server-authored): لا outbox عام ولا محرك ثانٍ —
  /// يستنزف العلم pending_sync ويمسحه بعد النجاح. offline يبقيه للمحاولة التالية.
  Future<int> push() async {
    if (!_isPullEnabled()) return 0;
    final userId = await _getAuthUserId();
    if (userId == null) return 0;

    final pending = await _db
        .customSelect(
          'SELECT server_id, status FROM smart_inbox_items '
          'WHERE pending_sync = 1;',
        )
        .get();
    var pushed = 0;
    for (final row in pending) {
      final serverId = row.read<String>('server_id');
      final status = row.read<String>('status');
      try {
        await _remoteSource.pushStatus(serverId, status);
        await _db.customStatement(
          'UPDATE smart_inbox_items SET pending_sync = 0, synced_at = '
          "${sqlString(dateTimeToSql(DateTime.now().toUtc()))} "
          'WHERE server_id = ${sqlString(serverId)};',
        );
        pushed++;
      } catch (e) {
        // offline / خطأ مؤقت — يبقى pending_sync=1 للمحاولة في الدورة التالية.
        if (kDebugMode) debugPrint('[SmartInboxSync] push item skipped: $e');
      }
    }
    if (kDebugMode) debugPrint('[SmartInboxSync] push done: pushed=$pushed');
    return pushed;
  }

  Future<SmartInboxSyncResult> pull({
    SyncCursor? from,
    bool Function()? isAdmitted,
  }) async {
    if (!_isPullEnabled()) return const SmartInboxSyncResult();

    final userId = await _getAuthUserId();
    if (userId == null) return const SmartInboxSyncResult();
    final admitted = isAdmitted ?? alwaysAdmitted;

    int imported = 0;
    int updated = 0;
    int tombstoned = 0;

    var reachedEof = false;
    try {
      var cursor = from ?? await readSyncCursor(_db, _cursorKey);
      while (true) {
        if (!admitted()) break;
        final rows = await _remoteSource.fetchRows(
          after: cursor,
          limit: _pageSize,
        );
        if (!admitted()) break;
        if (rows.isEmpty) {
          reachedEof = true;
          break;
        }

        final nextCursor = SyncCursor.fromServerRow(rows.last);
        final pageResult = await _db.transaction(() async {
          var pageImported = 0;
          var pageUpdated = 0;
          var pageTombstoned = 0;
          for (final row in rows) {
            if (row['deleted_at'] != null) {
              if (await _processTombstone(row)) pageTombstoned++;
              continue;
            }
            final outcome = await _processRow(row);
            switch (outcome) {
              case _RowOutcome.imported:
                pageImported++;
              case _RowOutcome.updated:
                pageUpdated++;
              case _RowOutcome.skipped:
                break;
            }
          }
          if (!admitted()) throw const ReconcilePullCancelled();
          await writeSyncCursor(_db, _cursorKey, nextCursor);
          return (
            imported: pageImported,
            updated: pageUpdated,
            tombstoned: pageTombstoned,
          );
        });
        imported += pageResult.imported;
        updated += pageResult.updated;
        tombstoned += pageResult.tombstoned;
        cursor = nextCursor;
        if (rows.length < _pageSize) {
          reachedEof = true;
          break;
        }
      }
    } on ReconcilePullCancelled {
      // Lifecycle/ownership cancellation, not a transport failure.
      if (kDebugMode) debugPrint('[SmartInboxSync] reconciliation cancelled');
    } catch (e) {
      if (kDebugMode) debugPrint('[SmartInboxSync] pull error: $e');
    }
    final status =
        reachedEof ? SyncPullStatus.completed : SyncPullStatus.failed;

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
      status: status,
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
