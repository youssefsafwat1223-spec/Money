import 'package:drift/drift.dart' show QueryRow;
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import '../../core/sync/outbox_failure.dart';
import '../db/app_database.dart';
import '../db/sql_value_codec.dart';
import 'sync_cursor.dart';

/// MALI-072n / MALI-008 — durable, offline-first sender-mapping sync.
///
/// Sender→bank mappings are user-owned learned configuration. This replaces the
/// old unbounded full-snapshot download (which also could not propagate a
/// deletion) with a stable keyset-paginated pull, tombstone deletion
/// propagation, a documented conflict policy, and typed error handling.
///
/// Conflict policy (documented): server-authoritative-timestamp last-write-wins.
///   • `updated_at` is server-owned (migration 0069 trigger), so it is monotonic
///     ACROSS devices — the keyset never skips a row.
///   • A pull NEVER overwrites a locally pending change; that change is pushed
///     and, being the newest server version, wins. So a stale device can never
///     roll back a value it did not touch, and an older remote snapshot never
///     overwrites a newer local edit.
///   • A remote tombstone soft-deletes the local row (unless a newer unsynced
///     local change exists); re-suggesting a sender is an explicit recreate that
///     un-tombstones it.
class SenderMappingSyncResult {
  const SenderMappingSyncResult({
    this.imported = 0,
    this.updated = 0,
    this.tombstoned = 0,
    this.pushed = 0,
    this.failed = 0,
  });

  final int imported;
  final int updated;
  final int tombstoned;
  final int pushed;
  final int failed;
}

/// Injectable remote store — real impl calls Supabase; tests supply a fake.
abstract class SenderMappingRemoteStore {
  /// Keyset page after [after], ordered by (updated_at, id) ascending.
  Future<List<Map<String, dynamic>>> fetchRows({
    required SyncCursor after,
    int limit,
  });

  /// Upsert one row keyed by (user_id, normalized_sender_id). A non-null
  /// `deleted_at` is a tombstone. Returns the stored rows (with the
  /// server-authoritative `updated_at`). Throws on a real error.
  Future<List<Map<String, dynamic>>> upsert(List<Map<String, dynamic>> rows);
}

class SupabaseSenderBankMappingRemoteStore implements SenderMappingRemoteStore {
  SupabaseSenderBankMappingRemoteStore(this._client);

  final supabase.SupabaseClient _client;
  static const _table = 'sender_bank_mappings';

  @override
  Future<List<Map<String, dynamic>>> fetchRows({
    required SyncCursor after,
    int limit = 200,
  }) async {
    final query = _client.from(_table).select();
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

  @override
  Future<List<Map<String, dynamic>>> upsert(
    List<Map<String, dynamic>> rows,
  ) async {
    if (rows.isEmpty) return const [];
    final response = await _client
        .from(_table)
        .upsert(rows, onConflict: 'user_id,normalized_sender_id')
        .select();
    return (response as List).cast<Map<String, dynamic>>();
  }
}

class SenderBankMappingSyncService {
  SenderBankMappingSyncService({
    required AppDatabase db,
    required SenderMappingRemoteStore remoteStore,
    required String? Function() currentUserId,
    int pageSize = 200,
  })  : assert(pageSize > 0),
        _db = db,
        _remoteStore = remoteStore,
        _currentUserId = currentUserId,
        _pageSize = pageSize;

  final AppDatabase _db;
  final SenderMappingRemoteStore _remoteStore;
  final String? Function() _currentUserId;
  final int _pageSize;

  static const _cursorKey = 'sender_bank_mappings';

  Future<SenderMappingSyncResult> sync() async {
    final userId = _currentUserId();
    if (userId == null || userId.trim().isEmpty) {
      return const SenderMappingSyncResult();
    }
    // Push local edits/deletes FIRST so they become the newest server version,
    // then pull remote changes.
    final pushResult = await push(userId);
    final pullResult = await pull(userId);
    return SenderMappingSyncResult(
      imported: pullResult.imported,
      updated: pullResult.updated,
      tombstoned: pullResult.tombstoned,
      pushed: pushResult.$1,
      failed: pushResult.$2,
    );
  }

  /// Uploads pending local mappings and tombstones with typed error handling.
  Future<(int, int)> push([String? forUserId]) async {
    final userId = forUserId ?? _currentUserId();
    if (userId == null || userId.trim().isEmpty) return (0, 0);

    // Uploadable = confirmed/rejected mappings OR any tombstone, that are not
    // already synced.
    final pending = await _db.customSelect(
      "SELECT * FROM sender_bank_mappings "
      "WHERE sync_status IN ('pending', 'failed') "
      "AND (deleted_at IS NOT NULL OR status IN ('confirmed', 'rejected'));",
    ).get();

    if (pending.isEmpty) return (0, 0);

    // MALI-029 — ONE batched upsert for the whole pending set (the remote sink
    // accepts a List) instead of a network round-trip per mapping, and the
    // synced-marking is committed in ONE transaction instead of one per row. The
    // server-authoritative updated_at is mapped back by the natural key
    // (normalized_sender_id). A batch loses per-item error isolation, so on ANY
    // batch failure we fall back to the accepted per-row path — one bad mapping
    // never fails the rest, and the natural-key duplicate is still resolved by the
    // upsert itself (no error).
    try {
      final serverRows = [for (final row in pending) _toServerRow(row, userId)];
      final stored = await _remoteStore.upsert(serverRows);
      final updatedByKey = <String, String?>{
        for (final s in stored)
          if (s['normalized_sender_id'] != null)
            s['normalized_sender_id'] as String: s['updated_at'] as String?,
      };
      await _db.transaction(() async {
        for (final row in pending) {
          await _markSynced(
            row.read<String>('id'),
            updatedByKey[row.read<String>('normalized_sender_id')],
          );
        }
      });
      if (kDebugMode) {
        debugPrint('[SenderMappingSync] push: pushed=${pending.length} '
            'failed=0 (batched)');
      }
      return (pending.length, 0);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[SenderMappingSync] batch push failed, per-row fallback: $e');
      }
      return _pushPerRow(pending, userId);
    }
  }

  /// Accepted per-row path (isolates a single bad mapping) — used as the fallback
  /// when the batched upsert fails.
  Future<(int, int)> _pushPerRow(
      List<QueryRow> pending, String userId) async {
    var pushed = 0;
    var failed = 0;
    for (final row in pending) {
      final id = row.read<String>('id');
      try {
        final stored = await _remoteStore.upsert([_toServerRow(row, userId)]);
        final serverUpdatedAt =
            stored.isEmpty ? null : stored.first['updated_at'] as String?;
        await _markSynced(id, serverUpdatedAt);
        pushed++;
      } catch (e) {
        final failureClass = classifyOutboxError(e);
        await _markFailed(id);
        failed++;
        if (kDebugMode) {
          debugPrint(
            '[SenderMappingSync] push failed (${failureClass.name}): $e',
          );
        }
      }
    }
    if (kDebugMode) {
      debugPrint('[SenderMappingSync] push: pushed=$pushed failed=$failed');
    }
    return (pushed, failed);
  }

  Future<({int imported, int updated, int tombstoned})> pull([
    String? forUserId,
  ]) async {
    final userId = forUserId ?? _currentUserId();
    if (userId == null || userId.trim().isEmpty) {
      return (imported: 0, updated: 0, tombstoned: 0);
    }

    var imported = 0;
    var updated = 0;
    var tombstoned = 0;
    try {
      var cursor = await readSyncCursor(_db, _cursorKey);
      while (true) {
        final rows =
            await _remoteStore.fetchRows(after: cursor, limit: _pageSize);
        if (rows.isEmpty) break;

        final nextCursor = SyncCursor.fromServerRow(rows.last);
        final page = await _db.transaction(() async {
          var pi = 0, pu = 0, pt = 0;
          for (final row in rows) {
            final outcome = row['deleted_at'] != null
                ? await _applyTombstone(row)
                : await _applyRow(row);
            switch (outcome) {
              case _Outcome.imported:
                pi++;
              case _Outcome.updated:
                pu++;
              case _Outcome.tombstoned:
                pt++;
              case _Outcome.skipped:
                break;
            }
          }
          // Cursor advances ATOMICALLY with the applied rows — a crash cannot
          // skip a page.
          await writeSyncCursor(_db, _cursorKey, nextCursor);
          return (pi, pu, pt);
        });
        imported += page.$1;
        updated += page.$2;
        tombstoned += page.$3;
        cursor = nextCursor;
        if (rows.length < _pageSize) break;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[SenderMappingSync] pull error: $e');
    }
    return (imported: imported, updated: updated, tombstoned: tombstoned);
  }

  Future<_Outcome> _applyRow(Map<String, dynamic> row) async {
    final normalized = row['normalized_sender_id'] as String?;
    if (normalized == null) return _Outcome.skipped;
    final serverUpdatedAt = row['updated_at'] as String?;
    final now = dateTimeToSql(DateTime.now().toUtc());

    final existing = await _db
        .customSelect(
          'SELECT sync_status, server_updated_at FROM sender_bank_mappings '
          'WHERE normalized_sender_id = ${sqlString(normalized)} LIMIT 1;',
        )
        .getSingleOrNull();

    if (existing != null) {
      // Never overwrite a locally pending change on pull — it is pushed and
      // wins by the server-authoritative timestamp.
      if (existing.readNullable<String>('sync_status') == 'pending') {
        return _Outcome.skipped;
      }
      // No-op when unchanged since we last synced (avoids UI churn).
      if (existing.readNullable<String>('server_updated_at') ==
          serverUpdatedAt) {
        return _Outcome.skipped;
      }
      await _db.customStatement('''
        UPDATE sender_bank_mappings SET
          sender_id = ${sqlString(row['sender_id'] as String? ?? '')},
          bank_key = ${sqlNullableString(row['bank_key'] as String?)},
          suggested_bank_name =
            ${sqlString(row['suggested_bank_name'] as String? ?? '')},
          suggested_country =
            ${sqlString(row['suggested_country'] as String? ?? '')},
          confidence = ${(row['confidence'] as num?)?.toDouble() ?? 0},
          reason = ${sqlNullableString(row['reason'] as String?)},
          status = ${sqlString(row['status'] as String? ?? 'pending')},
          source = ${sqlString(row['source'] as String? ?? 'remote')},
          last_seen_at = ${sqlString(_ts(row['last_seen_at']) ?? now)},
          confirmed_at = ${sqlNullableString(_ts(row['confirmed_at']))},
          rejected_at = ${sqlNullableString(_ts(row['rejected_at']))},
          rejection_expires_at =
            ${sqlNullableString(_ts(row['rejection_expires_at']))},
          updated_at = ${sqlString(_ts(serverUpdatedAt) ?? now)},
          server_updated_at = ${sqlNullableString(serverUpdatedAt)},
          synced_at = ${sqlString(now)},
          deleted_at = NULL,
          sync_status = 'synced'
        WHERE normalized_sender_id = ${sqlString(normalized)};
      ''');
      return _Outcome.updated;
    }

    // New remote mapping — import it.
    await _db.customStatement('''
      INSERT OR IGNORE INTO sender_bank_mappings(
        id, sender_id, normalized_sender_id, bank_key, suggested_bank_name,
        suggested_country, confidence, reason, status, source,
        first_seen_at, last_seen_at, confirmed_at, rejected_at,
        rejection_expires_at, created_at, updated_at, synced_at,
        server_updated_at, sync_status, deleted_at
      ) VALUES (
        ${sqlString(row['id'] as String? ?? normalized)},
        ${sqlString(row['sender_id'] as String? ?? '')},
        ${sqlString(normalized)},
        ${sqlNullableString(row['bank_key'] as String?)},
        ${sqlString(row['suggested_bank_name'] as String? ?? '')},
        ${sqlString(row['suggested_country'] as String? ?? '')},
        ${(row['confidence'] as num?)?.toDouble() ?? 0},
        ${sqlNullableString(row['reason'] as String?)},
        ${sqlString(row['status'] as String? ?? 'pending')},
        ${sqlString(row['source'] as String? ?? 'remote')},
        ${sqlString(_ts(row['first_seen_at']) ?? now)},
        ${sqlString(_ts(row['last_seen_at']) ?? now)},
        ${sqlNullableString(_ts(row['confirmed_at']))},
        ${sqlNullableString(_ts(row['rejected_at']))},
        ${sqlNullableString(_ts(row['rejection_expires_at']))},
        ${sqlString(_ts(row['created_at']) ?? now)},
        ${sqlString(_ts(serverUpdatedAt) ?? now)},
        ${sqlString(now)},
        ${sqlNullableString(serverUpdatedAt)},
        'synced',
        NULL
      );
    ''');
    return _Outcome.imported;
  }

  Future<_Outcome> _applyTombstone(Map<String, dynamic> row) async {
    final normalized = row['normalized_sender_id'] as String?;
    if (normalized == null) return _Outcome.skipped;
    final serverUpdatedAt = row['updated_at'] as String?;
    final now = dateTimeToSql(DateTime.now().toUtc());

    final existing = await _db
        .customSelect(
          'SELECT sync_status, deleted_at FROM sender_bank_mappings '
          'WHERE normalized_sender_id = ${sqlString(normalized)} LIMIT 1;',
        )
        .getSingleOrNull();
    if (existing == null) return _Outcome.skipped;
    // A locally pending change wins (it will push); don't apply the tombstone.
    if (existing.readNullable<String>('sync_status') == 'pending') {
      return _Outcome.skipped;
    }
    if (existing.readNullable<String>('deleted_at') != null) {
      return _Outcome.skipped; // already tombstoned
    }
    await _db.customStatement('''
      UPDATE sender_bank_mappings
      SET deleted_at = ${sqlString(_ts(serverUpdatedAt) ?? now)},
          server_updated_at = ${sqlNullableString(serverUpdatedAt)},
          updated_at = ${sqlString(_ts(serverUpdatedAt) ?? now)},
          synced_at = ${sqlString(now)},
          sync_status = 'synced'
      WHERE normalized_sender_id = ${sqlString(normalized)};
    ''');
    return _Outcome.tombstoned;
  }

  Map<String, dynamic> _toServerRow(dynamic row, String userId) {
    String? read(String c) => row.readNullable<String>(c) as String?;
    return {
      'user_id': userId,
      'sender_id': row.read<String>('sender_id'),
      'normalized_sender_id': row.read<String>('normalized_sender_id'),
      'bank_key': read('bank_key'),
      'suggested_bank_name': row.read<String>('suggested_bank_name'),
      'suggested_country': row.read<String>('suggested_country'),
      'confidence': row.read<double>('confidence'),
      'reason': read('reason'),
      'status': row.read<String>('status'),
      'source': row.read<String>('source'),
      'first_seen_at': row.read<String>('first_seen_at'),
      'last_seen_at': row.read<String>('last_seen_at'),
      'confirmed_at': read('confirmed_at'),
      'rejected_at': read('rejected_at'),
      'rejection_expires_at': read('rejection_expires_at'),
      'created_at': row.read<String>('created_at'),
      'deleted_at': read('deleted_at'),
      // updated_at is deliberately omitted — server-authoritative (0069).
    };
  }

  Future<void> _markSynced(String id, String? serverUpdatedAt) async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    final serverCols = serverUpdatedAt != null
        ? 'server_updated_at = ${sqlString(serverUpdatedAt)}, '
            'updated_at = ${sqlString(serverUpdatedAt)},'
        : '';
    await _db.customStatement('''
      UPDATE sender_bank_mappings
      SET sync_status = 'synced',
          $serverCols
          synced_at = ${sqlString(now)}
      WHERE id = ${sqlString(id)};
    ''');
  }

  Future<void> _markFailed(String id) async {
    await _db.customStatement(
      "UPDATE sender_bank_mappings SET sync_status = 'failed' "
      'WHERE id = ${sqlString(id)};',
    );
  }

  /// Normalises a server timestamp value to the local SQL (ISO8601) form.
  static String? _ts(Object? value) =>
      value == null ? null : dateTimeToSql(DateTime.parse(value.toString()));
}

enum _Outcome { imported, updated, tombstoned, skipped }
