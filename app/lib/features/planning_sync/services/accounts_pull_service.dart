import 'dart:convert';

import 'package:drift/drift.dart' show QueryRow;
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/backend/supabase_config.dart';
import '../../../core/utils/id_generator.dart';
import '../../../data/db/app_database.dart';
import '../../../data/db/bounded_lookup.dart';
import '../../../data/db/money_codec.dart';
import '../../../data/db/sql_value_codec.dart';
import '../../../data/sync/sync_cursor.dart';
import '../../../domain/finance/money.dart';
import '../../../domain/finance/money_transport.dart';

const accountsPullSelect = '*, initial_balance_text:initial_balance::text, '
    'current_balance_text:current_balance::text, '
    'credit_limit_text:credit_limit::text, '
    'available_credit_text:available_credit::text';
const accountsPullOrderColumns = ['updated_at', 'id'];

String accountsPullKeysetFilter(SyncCursor after) =>
    'updated_at.gt.${after.updatedAt},'
    'and(updated_at.eq.${after.updatedAt},id.gt.${after.id})';

({
  Money? initialBalanceMoney,
  Money? currentBalanceMoney,
  Money? creditLimitMoney,
  Money? availableCreditMoney,
}) deserializeAccountsPullMoney(Map<String, dynamic> row) {
  final currency = row['currency'];
  if (currency is! String) {
    throw const MoneyTransportException(
        'account pull requires a String currency');
  }
  return (
    initialBalanceMoney:
        moneyFromPulledValue(row['initial_balance_text'], currency),
    currentBalanceMoney:
        moneyFromPulledValue(row['current_balance_text'], currency),
    creditLimitMoney: moneyFromPulledValue(row['credit_limit_text'], currency),
    availableCreditMoney:
        moneyFromPulledValue(row['available_credit_text'], currency),
  );
}

class AccountsPullResult {
  const AccountsPullResult({
    this.imported = 0,
    this.updated = 0,
    this.conflicts = 0,
    this.tombstoned = 0,
    this.status = SyncPullStatus.deferred,
  });

  final int imported;
  final int updated;
  final int conflicts;
  final int tombstoned;
  final SyncPullStatus status;
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
    final query = _client.from('user_accounts').select(accountsPullSelect);
    final filtered =
        after.id.isEmpty ? query : query.or(accountsPullKeysetFilter(after));
    final response = await filtered
        .order(accountsPullOrderColumns[0], ascending: true)
        .order(accountsPullOrderColumns[1], ascending: true)
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

  /// [from] overrides the starting cursor for a reconciliation full re-pull
  /// (epoch) WITHOUT destructively resetting the persisted cursor first — the
  /// persisted cursor only advances as pages actually apply, so a deferred pull
  /// (feature/auth off) leaves it untouched. [isAdmitted] is checked at every
  /// page boundary; when it turns false the pull stops without applying more
  /// rows or advancing the cursor, and reports [SyncPullStatus.failed].
  Future<AccountsPullResult> pull({
    SyncCursor? from,
    bool Function()? isAdmitted,
  }) async {
    if (!_isEnabled()) return const AccountsPullResult();
    final userId = await _getAuthUserId();
    if (userId == null) return const AccountsPullResult();
    final admitted = isAdmitted ?? alwaysAdmitted;

    int imported = 0;
    int updated = 0;
    int conflicts = 0;
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
          var pageConflicts = 0;
          var pageTombstoned = 0;
          var anyTombstone = false;
          // MALI-029: resolve the whole page's server/local identity + meta in
          // two bounded lookups instead of a _findLocalId + meta SELECT per row.
          final identity = await _prefetchIdentity(rows);
          for (final row in rows) {
            if (row['deleted_at'] != null) {
              if (await _processTombstone(row, identity)) {
                pageTombstoned++;
                anyTombstone = true;
              }
              continue;
            }
            final outcome = await _processRow(row, identity);
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
          // A tombstone clears is_default on its row; guarantee one default
          // survives the page's deletions with a single check (was per-row).
          if (anyTombstone) await _ensureOneDefaultAccount();
          if (!admitted()) throw const ReconcilePullCancelled();
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
        if (rows.length < _pageSize) {
          reachedEof = true;
          break;
        }
      }
    } on ReconcilePullCancelled {
      // Lifecycle/ownership cancellation, not a transport failure: no retry,
      // no backoff, no remote-failure diagnostic. Leaves the pull non-completed.
      if (kDebugMode) debugPrint('[AccountsPull] reconciliation cancelled');
    } catch (e) {
      if (kDebugMode) debugPrint('[AccountsPull] pull error: $e');
    }

    final status =
        reachedEof ? SyncPullStatus.completed : SyncPullStatus.failed;
    if (kDebugMode) {
      debugPrint(
        '[AccountsPull] done: imported=$imported updated=$updated '
        'conflicts=$conflicts tombstoned=$tombstoned status=${status.name}',
      );
    }
    return AccountsPullResult(
      imported: imported,
      updated: updated,
      conflicts: conflicts,
      tombstoned: tombstoned,
      status: status,
    );
  }

  Future<_AccountPullOutcome> _processRow(
    Map<String, dynamic> row,
    _AccountIdentityIndex identity,
  ) async {
    final serverId = row['id'] as String?;
    if (serverId == null) return _AccountPullOutcome.skipped;

    final existing = identity.resolve(serverId, row['local_id'] as String?);
    final serverUpdatedAt = row['updated_at'] as String?;
    // MALI-022 / 0068 — server revision (CAS base); null when 0068 is absent.
    final serverRevision = (row['revision'] as num?)?.toInt();
    final now = dateTimeToSql(DateTime.now().toUtc());

    if (existing != null) {
      final localId = existing.id;
      final syncStatus = existing.syncStatus;
      if (syncStatus == 'conflict') return _AccountPullOutcome.conflict;
      if (syncStatus == 'pending') {
        await _markConflict(localId);
        return _AccountPullOutcome.conflict;
      }

      // No-op when unchanged since the last sync — avoids re-writing every
      // account each pull cycle, which would tick dbRevisionProvider and
      // flicker every screen. Only write when the server row actually moved.
      if (syncStatus == 'synced' &&
          existing.serverId == serverId &&
          existing.serverUpdatedAt == serverUpdatedAt) {
        return _AccountPullOutcome.skipped;
      }

      final pulledMoney = deserializeAccountsPullMoney(row);
      await _db.customStatement('''
        UPDATE accounts
        SET name = ${sqlString(row['name'] as String? ?? 'Account')},
            currency = ${sqlString(row['currency'] as String? ?? 'SAR')},
            type = ${sqlString(row['type'] as String? ?? 'bank')},
            initial_balance = ${kMoneyCodec.sqlNullableRealLiteral(pulledMoney.initialBalanceMoney)},
            initial_balance_minor = ${kMoneyCodec.sqlNullableMinorLiteral(pulledMoney.initialBalanceMoney)},
            current_balance = ${kMoneyCodec.sqlNullableRealLiteral(pulledMoney.currentBalanceMoney)},
            current_balance_minor = ${kMoneyCodec.sqlNullableMinorLiteral(pulledMoney.currentBalanceMoney)},
            bank_account_number = ${sqlNullableString(row['bank_account_number'] as String?)},
            credit_limit = ${kMoneyCodec.sqlNullableRealLiteral(pulledMoney.creditLimitMoney)},
            credit_limit_minor = ${kMoneyCodec.sqlNullableMinorLiteral(pulledMoney.creditLimitMoney)},
            available_credit = ${kMoneyCodec.sqlNullableRealLiteral(pulledMoney.availableCreditMoney)},
            available_credit_minor = ${kMoneyCodec.sqlNullableMinorLiteral(pulledMoney.availableCreditMoney)},
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
      // Keep the page index consistent if a later row in this same page
      // resolves to the row we just wrote (e.g. a duplicate local_id).
      identity.remember(
        id: localId,
        serverId: serverId,
        serverUpdatedAt: serverUpdatedAt,
      );
      return _AccountPullOutcome.updated;
    }

    final importedId = row['local_id'] as String? ?? IdGenerator.next();
    final pulledMoney = deserializeAccountsPullMoney(row);
    await _db.customStatement('''
      INSERT OR IGNORE INTO accounts(
        id, name, currency, type, initial_balance, initial_balance_minor,
        current_balance, current_balance_minor, bank_account_number,
        credit_limit, credit_limit_minor, available_credit, available_credit_minor,
        payment_due_day, wallet_provider, exclude_from_totals, metadata,
        is_default, sort_order, created_at, updated_at,
        server_id, synced_at, server_updated_at, server_revision, sync_status,
        deleted_at
      ) VALUES (
        ${sqlString(importedId)},
        ${sqlString(row['name'] as String? ?? 'Account')},
        ${sqlString(row['currency'] as String? ?? 'SAR')},
        ${sqlString(row['type'] as String? ?? 'bank')},
        ${kMoneyCodec.sqlNullableRealLiteral(pulledMoney.initialBalanceMoney)},
        ${kMoneyCodec.sqlNullableMinorLiteral(pulledMoney.initialBalanceMoney)},
        ${kMoneyCodec.sqlNullableRealLiteral(pulledMoney.currentBalanceMoney)},
        ${kMoneyCodec.sqlNullableMinorLiteral(pulledMoney.currentBalanceMoney)},
        ${sqlNullableString(row['bank_account_number'] as String?)},
        ${kMoneyCodec.sqlNullableRealLiteral(pulledMoney.creditLimitMoney)},
        ${kMoneyCodec.sqlNullableMinorLiteral(pulledMoney.creditLimitMoney)},
        ${kMoneyCodec.sqlNullableRealLiteral(pulledMoney.availableCreditMoney)},
        ${kMoneyCodec.sqlNullableMinorLiteral(pulledMoney.availableCreditMoney)},
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
    identity.remember(
      id: importedId,
      serverId: serverId,
      serverUpdatedAt: serverUpdatedAt,
    );
    return _AccountPullOutcome.imported;
  }

  Future<bool> _processTombstone(
    Map<String, dynamic> row,
    _AccountIdentityIndex identity,
  ) async {
    final serverId = row['id'] as String?;
    if (serverId == null) return false;
    final existing = identity.resolve(serverId, row['local_id'] as String?);
    if (existing == null) return false;

    final status = existing.syncStatus;
    if (status == 'conflict') return false;
    if (status == 'pending') {
      await _markConflict(existing.id);
      return false;
    }

    final localId = existing.id;
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
    // The single _ensureOneDefaultAccount() runs once after the page (pull()).
    identity.remember(
      id: localId,
      serverId: serverId,
      serverUpdatedAt: row['updated_at'] as String?,
    );
    return true;
  }

  /// Resolves the whole page's server/local identity and sync-meta in two
  /// bounded lookups (server_id IN …, id IN …) — replacing the per-row
  /// `_findLocalId` (up to 2 SELECTs) + meta SELECT. The result is server-id
  /// first, then local-id, exactly as the old per-row resolution ordered them.
  Future<_AccountIdentityIndex> _prefetchIdentity(
    List<Map<String, dynamic>> rows,
  ) async {
    final serverIds = <String>{};
    final localIds = <String>{};
    for (final row in rows) {
      final sid = row['id'] as String?;
      if (sid != null) serverIds.add(sid);
      final lid = row['local_id'] as String?;
      if (lid != null) localIds.add(lid);
    }
    final index = _AccountIdentityIndex();
    const columns =
        'SELECT id, server_id, sync_status, server_updated_at FROM accounts';
    final byServerRows = await selectByIdChunks(
      _db,
      serverIds,
      sql: (ph) => '$columns WHERE server_id IN ($ph);',
    );
    for (final r in byServerRows) {
      index._add(_AccountMeta.fromRow(r));
    }
    final byLocalRows = await selectByIdChunks(
      _db,
      localIds,
      sql: (ph) => '$columns WHERE id IN ($ph);',
    );
    for (final r in byLocalRows) {
      index._add(_AccountMeta.fromRow(r));
    }
    return index;
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

/// One account row's identity + sync-meta, as prefetched for a pull page.
class _AccountMeta {
  const _AccountMeta({
    required this.id,
    required this.serverId,
    required this.syncStatus,
    required this.serverUpdatedAt,
  });

  factory _AccountMeta.fromRow(QueryRow row) => _AccountMeta(
        id: row.read<String>('id'),
        serverId: row.readNullable<String>('server_id'),
        syncStatus: row.readNullable<String>('sync_status'),
        serverUpdatedAt: row.readNullable<String>('server_updated_at'),
      );

  final String id;
  final String? serverId;
  final String? syncStatus;
  final String? serverUpdatedAt;
}

/// Page-scoped resolver: server_id → meta and local id → meta. Rebuilt per page
/// (never an instance/static field), so a same-UID relogin with a new admission
/// generation always resolves against the freshly-committed local state and can
/// never reuse a stale cross-page/cross-owner map.
class _AccountIdentityIndex {
  final Map<String, _AccountMeta> _byServer = {};
  final Map<String, _AccountMeta> _byLocal = {};

  void _add(_AccountMeta meta) {
    _byLocal[meta.id] = meta;
    final serverId = meta.serverId;
    if (serverId != null) _byServer.putIfAbsent(serverId, () => meta);
  }

  /// server_id first, then local id — identical to the old `_findLocalId`.
  _AccountMeta? resolve(String serverId, String? localId) {
    final byServer = _byServer[serverId];
    if (byServer != null) return byServer;
    if (localId == null) return null;
    return _byLocal[localId];
  }

  /// After a write, refresh the index so a later same-page row that resolves to
  /// this account (e.g. a duplicate local_id) sees the just-committed synced
  /// state — keeping the batched path bit-identical to the old per-row re-read.
  void remember({
    required String id,
    required String serverId,
    required String? serverUpdatedAt,
  }) {
    final meta = _AccountMeta(
      id: id,
      serverId: serverId,
      syncStatus: 'synced',
      serverUpdatedAt: serverUpdatedAt,
    );
    _byLocal[id] = meta;
    _byServer[serverId] = meta;
  }
}
