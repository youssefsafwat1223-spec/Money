import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'ledger_sync_engine.dart';

import '../../../core/backend/supabase_config.dart';
import '../../../core/utils/id_generator.dart';
import '../../../data/db/app_database.dart';
import '../../../data/db/sql_value_codec.dart';
import '../../../data/repositories/drift_dedup_store.dart';
import '../../../data/repositories/drift_transaction_repository.dart';
import '../../../domain/entities/transaction_entity.dart';

class LedgerSyncResult {
  const LedgerSyncResult({
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

/// Injectable remote source — real impl calls Supabase; test impl returns
/// fixture rows without network access.
abstract class LedgerRemoteSource {
  Future<List<Map<String, dynamic>>> fetchActiveRows({int limit});
  Future<List<Map<String, dynamic>>> fetchTombstones({int limit});
}

class SupabaseLedgerRemoteSource implements LedgerRemoteSource {
  const SupabaseLedgerRemoteSource();

  @override
  Future<List<Map<String, dynamic>>> fetchActiveRows({int limit = 200}) async {
    final response = await Supabase.instance.client
        .from('user_transactions')
        .select()
        .order('occurred_at', ascending: false)
        .limit(limit);
    return (response as List)
        .cast<Map<String, dynamic>>()
        .where((r) => r['deleted_at'] == null)
        .toList();
  }

  @override
  Future<List<Map<String, dynamic>>> fetchTombstones({int limit = 200}) async {
    final response = await Supabase.instance.client
        .from('user_transactions')
        .select('id, deleted_at, updated_at')
        .order('updated_at', ascending: false)
        .limit(limit);
    return (response as List)
        .cast<Map<String, dynamic>>()
        .where((r) => r['deleted_at'] != null)
        .toList();
  }
}

class LedgerSyncService implements LedgerPullAdapter {
  LedgerSyncService({
    required AppDatabase db,
    required DriftTransactionRepository transactionRepository,
    required DriftDedupStore dedupStore,
    required bool Function() isPullEnabled,
    LedgerRemoteSource? remoteSource,
    Future<String?> Function()? getAuthUserId,
  })  : _db = db,
        _transactionRepository = transactionRepository,
        _dedupStore = dedupStore,
        _isPullEnabled = isPullEnabled,
        _remoteSource = remoteSource ?? const SupabaseLedgerRemoteSource(),
        _getAuthUserId = getAuthUserId ?? _defaultGetAuthUserId;

  static final _payloadMarkerTime =
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

  static String _payloadHash(String payloadId) => 'capture_payload:$payloadId';

  static Future<String?> _defaultGetAuthUserId() async {
    if (!SupabaseConfig.isConfigured) return null;
    try {
      return Supabase.instance.client.auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  final AppDatabase _db;
  final DriftTransactionRepository _transactionRepository;
  final DriftDedupStore _dedupStore;
  final bool Function() _isPullEnabled;
  final LedgerRemoteSource _remoteSource;
  final Future<String?> Function() _getAuthUserId;

  @override
  Future<LedgerSyncResult> pull() async {
    if (!_isPullEnabled()) return const LedgerSyncResult();

    final userId = await _getAuthUserId();
    if (userId == null) return const LedgerSyncResult();

    int imported = 0;
    int updated = 0;
    int conflicts = 0;
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
            case _RowOutcome.conflict:
              conflicts++;
            case _RowOutcome.skipped:
              break;
          }
        } catch (e) {
          if (kDebugMode) debugPrint('[LedgerSync] row error: $e');
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[LedgerSync] fetch error: $e');
    }

    try {
      final deletedRows = await _remoteSource.fetchTombstones();
      for (final row in deletedRows) {
        try {
          if (await _processTombstone(row)) tombstoned++;
        } catch (e) {
          if (kDebugMode) debugPrint('[LedgerSync] tombstone error: $e');
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[LedgerSync] tombstone fetch error: $e');
    }

    if (kDebugMode) {
      debugPrint(
        '[LedgerSync] done: imported=$imported updated=$updated '
        'conflicts=$conflicts tombstoned=$tombstoned',
      );
    }
    return LedgerSyncResult(
      imported: imported,
      updated: updated,
      conflicts: conflicts,
      tombstoned: tombstoned,
    );
  }

  Future<_RowOutcome> _processRow(Map<String, dynamic> row) async {
    final serverId = row['id'] as String?;
    if (serverId == null) return _RowOutcome.skipped;

    final payloadId = row['source_payload_id'] as String?;
    final serverUpdatedAt = row['updated_at'] as String?;
    final now = dateTimeToSql(DateTime.now().toUtc());

    final localId = await _findLocalId(serverId, payloadId);

    if (localId != null) {
      final meta = await _db
          .customSelect(
            'SELECT sync_status, server_id, server_updated_at, account_id '
            'FROM transactions WHERE id = ${sqlString(localId)} LIMIT 1;',
          )
          .getSingleOrNull();
      if (meta == null) return _RowOutcome.skipped;

      final syncStatus = meta.readNullable<String>('sync_status');
      if (syncStatus == 'conflict') {
        return _RowOutcome.conflict;
      }

      // Account repair: a sign-out wipe regenerates local account ids, so a
      // previously-imported transaction can point at an account id that no
      // longer exists — invisible in every account-scoped screen. Resolve the
      // authoritative local account (server_account_id → accounts.server_id)
      // and re-point synced rows whose stored account is stale. Pending local
      // edits are left untouched.
      final currentAccountId = meta.readNullable<String>('account_id');
      final resolvedAccountId = await _resolveLocalAccountId(row);
      final currentAccountValid = currentAccountId == null ||
          await _localAccountExists(currentAccountId);
      final accountNeedsRepair = syncStatus == 'synced' &&
          (!currentAccountValid ||
              (resolvedAccountId != null &&
                  resolvedAccountId != currentAccountId));

      // No-op when the server row is unchanged since we last synced it —
      // re-writing synced_at every pull cycle ticks dbRevisionProvider and
      // forces a visible reload of every screen (the "flicker"). Only write
      // when something actually differs.
      final alreadySynced = syncStatus == 'synced' &&
          meta.readNullable<String>('server_id') == serverId &&
          meta.readNullable<String>('server_updated_at') == serverUpdatedAt;
      if (alreadySynced && !accountNeedsRepair) return _RowOutcome.skipped;

      await _db.customStatement('''
        UPDATE transactions
        SET server_id = ${sqlString(serverId)},
            synced_at = ${sqlString(now)},
            server_updated_at = ${sqlNullableString(serverUpdatedAt)},
            ${accountNeedsRepair ? 'account_id = ${sqlNullableString(resolvedAccountId)},' : ''}
            sync_status = 'synced'
        WHERE id = ${sqlString(localId)};
      ''');
      return _RowOutcome.updated;
    }

    // No local row — import from server.
    final entity = _rowToEntity(
      row,
      accountId: await _resolveLocalAccountId(row),
    );
    if (entity == null) return _RowOutcome.skipped;

    try {
      await _transactionRepository.saveTransaction(
        transaction: entity,
        // Server stores the stable category KEY; saveTransaction resolves it
        // back to the local category id, so a pulled row keeps its category.
        categoryKey: row['category_id'] as String?,
      );
    } catch (_) {
      return _RowOutcome.skipped;
    }

    await _db.customStatement('''
      UPDATE transactions
      SET server_id = ${sqlString(serverId)},
          synced_at = ${sqlString(now)},
          server_updated_at = ${sqlNullableString(serverUpdatedAt)},
          sync_status = 'synced'
      WHERE id = ${sqlString(entity.id)};
    ''');

    if (payloadId != null) {
      await _dedupStore.mark(
        _payloadHash(payloadId),
        transactionId: entity.id,
        occurredAt: _payloadMarkerTime,
      );
    }

    return _RowOutcome.imported;
  }

  Future<bool> _processTombstone(Map<String, dynamic> row) async {
    final serverId = row['id'] as String?;
    if (serverId == null) return false;
    final localId = await _findLocalId(serverId, null);
    if (localId == null) return false;

    final meta = await _db
        .customSelect(
          "SELECT status, sync_status FROM transactions WHERE id = ${sqlString(localId)} LIMIT 1;",
        )
        .getSingleOrNull();
    if (meta == null) return false;

    final syncStatus = meta.readNullable<String>('sync_status');
    final status = meta.read<String>('status');
    if (syncStatus == 'conflict' || status == 'ignored') return false;

    await _db.customStatement('''
      UPDATE transactions
      SET status = 'ignored',
          updated_at = ${sqlString(dateTimeToSql(DateTime.now().toUtc()))}
      WHERE id = ${sqlString(localId)};
    ''');
    return true;
  }

  Future<String?> _findLocalId(String serverId, String? payloadId) async {
    final byServer = await _db
        .customSelect(
          "SELECT id FROM transactions "
          "WHERE server_id = ${sqlString(serverId)} AND status != 'ignored' "
          "LIMIT 1;",
        )
        .getSingleOrNull();
    if (byServer != null) return byServer.read<String>('id');

    if (payloadId != null) {
      return _dedupStore.transactionIdFor(
        _payloadHash(payloadId),
        _payloadMarkerTime,
      );
    }
    return null;
  }

  /// Maps a pulled server row to a local entity. [accountId] must be the
  /// pre-resolved LOCAL account id (see [_resolveLocalAccountId]) — the raw
  /// `local_account_id` column is a device-local id from whichever install
  /// pushed the row and is meaningless after a sign-out wipe regenerated the
  /// local accounts; importing it verbatim orphans the transaction.
  TransactionEntity? _rowToEntity(
    Map<String, dynamic> row, {
    String? accountId,
  }) {
    final amount = (row['amount'] as num?)?.toDouble();
    final currency = row['currency'] as String?;
    final occurredAt = row['occurred_at'] as String?;
    if (amount == null || currency == null || occurredAt == null) return null;

    final now = DateTime.now().toUtc();
    return TransactionEntity(
      id: IdGenerator.next(),
      amount: amount,
      currency: currency,
      rawMerchant: row['merchant'] as String?,
      type: _mapType(row['transaction_type'] as String? ?? 'unknown'),
      source: _mapSource(row['source'] as String? ?? 'unknown'),
      accountId: accountId,
      // Card linkage lives in metadata.last4 on the server (no dedicated
      // column); restore it so pulled transactions stay linked to their card.
      cardLast4: _last4FromMetadata(row['metadata']),
      balanceAfter: (row['balance_after'] as num?)?.toDouble(),
      foreignAmount: (row['foreign_amount'] as num?)?.toDouble(),
      foreignCurrency: row['foreign_currency'] as String?,
      occurredAt: DateTime.tryParse(occurredAt)?.toUtc() ?? now,
      rawMessage: '',
      parseConfidence: (row['confidence'] as num?)?.toDouble() ?? 0.0,
      // Direct-written needs_review captures land server-side as 'pending' —
      // keep that so the confirm flow still applies; everything else confirmed.
      status: row['status'] == 'pending'
          ? TransactionStatus.pending
          : TransactionStatus.confirmed,
      createdAt: now,
      updatedAt: now,
    );
  }

  /// Resolves the LOCAL account a pulled transaction belongs to.
  /// `server_account_id` is authoritative: it survives sign-out wipes because
  /// the accounts pull re-attaches `accounts.server_id` on import. The raw
  /// `local_account_id` is only trusted when that account actually exists
  /// locally. Returns null (unassigned) otherwise — visible via the
  /// currency-scoped fallback, unlike a dangling account reference.
  Future<String?> _resolveLocalAccountId(Map<String, dynamic> row) async {
    final serverAccountId = row['server_account_id'] as String?;
    if (serverAccountId != null) {
      final match = await _db
          .customSelect(
            'SELECT id FROM accounts '
            'WHERE server_id = ${sqlString(serverAccountId)} '
            'AND deleted_at IS NULL LIMIT 1;',
          )
          .getSingleOrNull();
      if (match != null) return match.read<String>('id');
    }
    final localAccountId = row['local_account_id'] as String?;
    if (localAccountId != null && await _localAccountExists(localAccountId)) {
      return localAccountId;
    }
    return null;
  }

  Future<bool> _localAccountExists(String id) async {
    final row = await _db
        .customSelect(
          'SELECT 1 AS x FROM accounts '
          'WHERE id = ${sqlString(id)} AND deleted_at IS NULL LIMIT 1;',
        )
        .getSingleOrNull();
    return row != null;
  }

  /// Server `metadata` is jsonb (a Map from postgrest); pull the card last4 out
  /// of it, tolerating a missing/oddly-typed value.
  String? _last4FromMetadata(dynamic metadata) {
    if (metadata is Map && metadata['last4'] != null) {
      return metadata['last4'].toString();
    }
    return null;
  }

  TransactionTypeEntity _mapType(String serverType) => switch (serverType) {
        'income' => TransactionTypeEntity.income,
        'expense' => TransactionTypeEntity.payment,
        'transfer' => TransactionTypeEntity.transfer,
        'refund' => TransactionTypeEntity.refund,
        _ => TransactionTypeEntity.unknown,
      };

  TransactionSourceEntity _mapSource(String serverSource) =>
      switch (serverSource) {
        'ios_shortcut' ||
        'android_sms' ||
        'share_extension' =>
          TransactionSourceEntity.bank,
        _ => TransactionSourceEntity.unknown,
      };
}

enum _RowOutcome { imported, updated, conflict, skipped }
