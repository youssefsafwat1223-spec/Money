import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/backend/supabase_config.dart';
import '../../../core/utils/id_generator.dart';
import '../../../data/db/app_database.dart';
import '../../../data/db/sql_value_codec.dart';
import '../../../data/sync/sync_cursor.dart';

class AccountsPullResult {
  const AccountsPullResult({
    this.imported = 0,
    this.updated = 0,
    this.conflicts = 0,
    this.tombstoned = 0,
  });

  final int imported;
  final int updated;
  final int conflicts;
  final int tombstoned;
}

abstract class AccountsRemoteSource {
  Future<List<Map<String, dynamic>>> fetchRows({
    required SyncCursor after,
    int limit,
  });
}

class SupabaseAccountsRemoteSource implements AccountsRemoteSource {
  const SupabaseAccountsRemoteSource();

  SupabaseClient get _client => Supabase.instance.client;

  @override
  Future<List<Map<String, dynamic>>> fetchRows({
    required SyncCursor after,
    int limit = 200,
  }) async {
    final query = _client.from('user_accounts').select();
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

class AccountsPullService {
  AccountsPullService({
    required AppDatabase db,
    required bool Function() isEnabled,
    Future<String?> Function()? getAuthUserId,
    AccountsRemoteSource? remoteSource,
    int pageSize = 200,
  })  : assert(pageSize > 0),
        _db = db,
        _isEnabled = isEnabled,
        _getAuthUserId = getAuthUserId ?? _defaultGetAuthUserId,
        _pageSize = pageSize,
        _remoteSource = remoteSource ?? const SupabaseAccountsRemoteSource();

  final AppDatabase _db;
  final bool Function() _isEnabled;
  final Future<String?> Function() _getAuthUserId;
  final AccountsRemoteSource _remoteSource;
  final int _pageSize;

  static const _cursorKey = 'accounts';

  static Future<String?> _defaultGetAuthUserId() async {
    if (!SupabaseConfig.isConfigured) return null;
    try {
      return Supabase.instance.client.auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  Future<AccountsPullResult> pull() async {
    if (!_isEnabled()) return const AccountsPullResult();
    final userId = await _getAuthUserId();
    if (userId == null) return const AccountsPullResult();

    int imported = 0;
    int updated = 0;
    int conflicts = 0;
    int tombstoned = 0;

    try {
      var cursor = await readSyncCursor(_db, _cursorKey);
      while (true) {
        final rows = await _remoteSource.fetchRows(
          after: cursor,
          limit: _pageSize,
        );
        if (rows.isEmpty) break;

        final nextCursor = SyncCursor.fromServerRow(rows.last);
        final pageResult = await _db.transaction(() async {
          var pageImported = 0;
          var pageUpdated = 0;
          var pageConflicts = 0;
          var pageTombstoned = 0;
          for (final row in rows) {
            if (row['deleted_at'] != null) {
              if (await _processTombstone(row)) pageTombstoned++;
              continue;
            }
            final outcome = await _processRow(row);
            switch (outcome) {
              case _AccountPullOutcome.imported:
                pageImported++;
              case _AccountPullOutcome.updated:
                pageUpdated++;
              case _AccountPullOutcome.conflict:
                pageConflicts++;
              case _AccountPullOutcome.skipped:
                break;
            }
          }
          await writeSyncCursor(_db, _cursorKey, nextCursor);
          return (
            imported: pageImported,
            updated: pageUpdated,
            conflicts: pageConflicts,
            tombstoned: pageTombstoned,
          );
        });
        imported += pageResult.imported;
        updated += pageResult.updated;
        conflicts += pageResult.conflicts;
        tombstoned += pageResult.tombstoned;
        cursor = nextCursor;
        if (rows.length < _pageSize) break;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[AccountsPull] pull error: $e');
    }

    if (kDebugMode) {
      debugPrint(
        '[AccountsPull] done: imported=$imported updated=$updated '
        'conflicts=$conflicts tombstoned=$tombstoned',
      );
    }
    return AccountsPullResult(
      imported: imported,
      updated: updated,
      conflicts: conflicts,
      tombstoned: tombstoned,
    );
  }

  Future<_AccountPullOutcome> _processRow(Map<String, dynamic> row) async {
    final serverId = row['id'] as String?;
    if (serverId == null) return _AccountPullOutcome.skipped;

    final localId = await _findLocalId(serverId, row['local_id'] as String?);
    final serverUpdatedAt = row['updated_at'] as String?;
    // MALI-022 / 0068 — server revision (CAS base); null when 0068 is absent.
    final serverRevision = (row['revision'] as num?)?.toInt();
    final now = dateTimeToSql(DateTime.now().toUtc());

    if (localId != null) {
      final meta = await _db
          .customSelect(
            'SELECT sync_status, server_id, server_updated_at FROM accounts '
            'WHERE id = ${sqlString(localId)} LIMIT 1;',
          )
          .getSingleOrNull();
      if (meta == null) return _AccountPullOutcome.skipped;

      final syncStatus = meta.readNullable<String>('sync_status');
      if (syncStatus == 'conflict') return _AccountPullOutcome.conflict;
      if (syncStatus == 'pending') {
        await _markConflict(localId);
        return _AccountPullOutcome.conflict;
      }

      // No-op when unchanged since the last sync — avoids re-writing every
      // account each pull cycle, which would tick dbRevisionProvider and
      // flicker every screen. Only write when the server row actually moved.
      if (syncStatus == 'synced' &&
          meta.readNullable<String>('server_id') == serverId &&
          meta.readNullable<String>('server_updated_at') == serverUpdatedAt) {
        return _AccountPullOutcome.skipped;
      }

      await _db.customStatement('''
        UPDATE accounts
        SET name = ${sqlString(row['name'] as String? ?? 'Account')},
            currency = ${sqlString(row['currency'] as String? ?? 'SAR')},
            type = ${sqlString(row['type'] as String? ?? 'bank')},
            initial_balance = ${sqlNullableNum(row['initial_balance'] as num?)},
            current_balance = ${sqlNullableNum(row['current_balance'] as num?)},
            bank_account_number = ${sqlNullableString(row['bank_account_number'] as String?)},
            credit_limit = ${sqlNullableNum(row['credit_limit'] as num?)},
            available_credit = ${sqlNullableNum(row['available_credit'] as num?)},
            payment_due_day = ${sqlNullableNum((row['payment_due_day'] as num?)?.toInt())},
            wallet_provider = ${sqlNullableString(row['wallet_provider'] as String?)},
            exclude_from_totals = ${(row['exclude_from_totals'] == true) ? 1 : 0},
            metadata = ${_metadataLiteral(row['metadata'])},
            is_default = ${(row['is_default'] == true) ? 1 : 0},
            sort_order = ${(row['sort_order'] as num?)?.toInt() ?? 0},
            updated_at = ${sqlString(_dateString(row['updated_at']) ?? now)},
            server_id = ${sqlString(serverId)},
            synced_at = ${sqlString(now)},
            server_updated_at = ${sqlNullableString(serverUpdatedAt)},
            server_revision = ${sqlNullableNum(serverRevision)},
            sync_status = 'synced',
            deleted_at = NULL
        WHERE id = ${sqlString(localId)};
      ''');
      return _AccountPullOutcome.updated;
    }

    final importedId = row['local_id'] as String? ?? IdGenerator.next();
    await _db.customStatement('''
      INSERT OR IGNORE INTO accounts(
        id, name, currency, type, initial_balance, current_balance,
        bank_account_number, credit_limit, available_credit,
        payment_due_day, wallet_provider, exclude_from_totals, metadata,
        is_default, sort_order, created_at, updated_at,
        server_id, synced_at, server_updated_at, server_revision, sync_status,
        deleted_at
      ) VALUES (
        ${sqlString(importedId)},
        ${sqlString(row['name'] as String? ?? 'Account')},
        ${sqlString(row['currency'] as String? ?? 'SAR')},
        ${sqlString(row['type'] as String? ?? 'bank')},
        ${sqlNullableNum(row['initial_balance'] as num?)},
        ${sqlNullableNum(row['current_balance'] as num?)},
        ${sqlNullableString(row['bank_account_number'] as String?)},
        ${sqlNullableNum(row['credit_limit'] as num?)},
        ${sqlNullableNum(row['available_credit'] as num?)},
        ${sqlNullableNum((row['payment_due_day'] as num?)?.toInt())},
        ${sqlNullableString(row['wallet_provider'] as String?)},
        ${(row['exclude_from_totals'] == true) ? 1 : 0},
        ${_metadataLiteral(row['metadata'])},
        ${(row['is_default'] == true) ? 1 : 0},
        ${(row['sort_order'] as num?)?.toInt() ?? 0},
        ${sqlString(_dateString(row['created_at']) ?? now)},
        ${sqlString(_dateString(row['updated_at']) ?? now)},
        ${sqlString(serverId)},
        ${sqlString(now)},
        ${sqlNullableString(serverUpdatedAt)},
        ${sqlNullableNum(serverRevision)},
        'synced',
        NULL
      );
    ''');
    return _AccountPullOutcome.imported;
  }

  Future<bool> _processTombstone(Map<String, dynamic> row) async {
    final serverId = row['id'] as String?;
    if (serverId == null) return false;
    final localId = await _findLocalId(serverId, row['local_id'] as String?);
    if (localId == null) return false;

    final meta = await _db
        .customSelect(
          'SELECT sync_status FROM accounts WHERE id = ${sqlString(localId)} LIMIT 1;',
        )
        .getSingleOrNull();
    if (meta == null) return false;
    final status = meta.readNullable<String>('sync_status');
    if (status == 'conflict') return false;
    if (status == 'pending') {
      await _markConflict(localId);
      return false;
    }

    final now = dateTimeToSql(DateTime.now().toUtc());
    final deletedAt = _dateString(row['deleted_at']) ?? now;
    await _db.customStatement('''
      UPDATE accounts
      SET deleted_at = ${sqlString(deletedAt)},
          server_id = ${sqlString(serverId)},
          server_updated_at = ${sqlNullableString(row['updated_at'] as String?)},
          server_revision = ${sqlNullableNum((row['revision'] as num?)?.toInt())},
          synced_at = ${sqlString(now)},
          sync_status = 'synced',
          is_default = 0
      WHERE id = ${sqlString(localId)};
    ''');
    await _ensureOneDefaultAccount();
    return true;
  }

  Future<String?> _findLocalId(String serverId, String? localId) async {
    final byServer = await _db
        .customSelect(
          'SELECT id FROM accounts WHERE server_id = ${sqlString(serverId)} LIMIT 1;',
        )
        .getSingleOrNull();
    if (byServer != null) return byServer.read<String>('id');

    if (localId == null) return null;
    final byLocal = await _db
        .customSelect(
          'SELECT id FROM accounts WHERE id = ${sqlString(localId)} LIMIT 1;',
        )
        .getSingleOrNull();
    return byLocal?.read<String>('id');
  }

  Future<void> _markConflict(String localId) async {
    await _db.customStatement('''
      UPDATE accounts
      SET sync_status = 'conflict'
      WHERE id = ${sqlString(localId)};
    ''');
  }

  Future<void> _ensureOneDefaultAccount() async {
    final row = await _db.customSelect('''
      SELECT id FROM accounts
      WHERE deleted_at IS NULL AND is_default = 1
      LIMIT 1;
    ''').getSingleOrNull();
    if (row != null) return;
    await _db.customStatement('''
      UPDATE accounts
      SET is_default = 1
      WHERE id = (
        SELECT id FROM accounts
        WHERE deleted_at IS NULL
        ORDER BY sort_order ASC, created_at ASC
        LIMIT 1
      );
    ''');
  }

  String? _dateString(Object? value) {
    if (value is String && value.isNotEmpty) return value;
    return null;
  }

  /// يحوّل metadata القادمة من الخادم (jsonb → Map/List) إلى قيمة SQL: NULL
  /// أو نص JSON مقتبس للتخزين في عمود TEXT المحلي.
  String _metadataLiteral(Object? value) {
    if (value == null) return 'NULL';
    if (value is String) {
      return value.isEmpty ? 'NULL' : sqlString(value);
    }
    return sqlString(jsonEncode(value));
  }
}

enum _AccountPullOutcome { imported, updated, conflict, skipped }
