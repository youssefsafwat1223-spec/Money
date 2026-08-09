import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'ledger_sync_engine.dart';

import '../../../core/backend/supabase_config.dart';
import '../../../core/utils/id_generator.dart';
import '../../../data/db/app_database.dart';
import '../../../data/db/sql_value_codec.dart';
import '../../../data/repositories/drift_dedup_store.dart';
import '../../../data/repositories/drift_transaction_repository.dart';
import '../../../data/sync/sync_cursor.dart';
import '../../../domain/entities/transaction_entity.dart';
import 'ledger_payload.dart';

class LedgerSyncResult {
  const LedgerSyncResult({
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

/// Injectable remote source — real impl calls Supabase; test impl returns
/// fixture rows without network access.
abstract class LedgerRemoteSource {
  Future<List<Map<String, dynamic>>> fetchRows({
    required SyncCursor after,
    int limit,
  });
}

class SupabaseLedgerRemoteSource implements LedgerRemoteSource {
  const SupabaseLedgerRemoteSource();

  @override
  Future<List<Map<String, dynamic>>> fetchRows({
    required SyncCursor after,
    int limit = 200,
  }) async {
    final query = Supabase.instance.client.from('user_transactions').select();
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

class LedgerSyncService implements LedgerPullAdapter {
  LedgerSyncService({
    required AppDatabase db,
    required DriftTransactionRepository transactionRepository,
    required DriftDedupStore dedupStore,
    required bool Function() isPullEnabled,
    LedgerRemoteSource? remoteSource,
    Future<String?> Function()? getAuthUserId,
    int pageSize = 200,
  })  : assert(pageSize > 0),
        _db = db,
        _transactionRepository = transactionRepository,
        _dedupStore = dedupStore,
        _isPullEnabled = isPullEnabled,
        _remoteSource = remoteSource ?? const SupabaseLedgerRemoteSource(),
        _pageSize = pageSize,
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
  final int _pageSize;

  // MALI-029 (pull batching) — resolution snapshots primed ONCE per pull instead
  // of a SELECT per row. A ledger pull only WRITES transactions; it never creates
  // accounts/categories (accounts are pulled earlier in the same single-flight
  // pump), so a start-of-pull snapshot is valid for every page. Cleared when pull
  // finishes; a null cache falls back to the original per-call SELECT.
  Map<String, String>? _accountServerToLocal; // accounts.server_id → accounts.id
  Set<String>? _localAccountIds; // non-deleted accounts.id
  Map<String, String>? _categoryKeyToLocal; // categories.key → categories.id

  Future<void> _primeResolutionCaches() async {
    final accounts = await _db
        .customSelect(
          'SELECT id, server_id FROM accounts WHERE deleted_at IS NULL;',
        )
        .get();
    final serverToLocal = <String, String>{};
    final ids = <String>{};
    for (final a in accounts) {
      final id = a.read<String>('id');
      ids.add(id);
      final serverId = a.readNullable<String>('server_id');
      if (serverId != null) serverToLocal[serverId] = id;
    }
    final categories =
        await _db.customSelect('SELECT id, key FROM categories;').get();
    final keyToLocal = <String, String>{
      for (final c in categories)
        c.read<String>('key'): c.read<String>('id'),
    };
    _accountServerToLocal = serverToLocal;
    _localAccountIds = ids;
    _categoryKeyToLocal = keyToLocal;
  }

  void _clearResolutionCaches() {
    _accountServerToLocal = null;
    _localAccountIds = null;
    _categoryKeyToLocal = null;
  }

  static const _cursorKey = 'ledger_transactions';

  @override
  Future<LedgerSyncResult> pull({
    SyncCursor? from,
    bool Function()? isAdmitted,
  }) async {
    if (!_isPullEnabled()) return const LedgerSyncResult();

    final userId = await _getAuthUserId();
    if (userId == null) return const LedgerSyncResult();
    final admitted = isAdmitted ?? alwaysAdmitted;

    int imported = 0;
    int updated = 0;
    int conflicts = 0;
    int tombstoned = 0;

    var reachedEof = false;
    try {
      // Prime the account/category resolution snapshots once for the whole pull.
      await _primeResolutionCaches();
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
              case _RowOutcome.conflict:
                pageConflicts++;
              case _RowOutcome.skipped:
                break;
            }
          }
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
      // Lifecycle/ownership cancellation, not a transport failure.
      if (kDebugMode) debugPrint('[LedgerSync] reconciliation cancelled');
    } catch (e) {
      if (kDebugMode) debugPrint('[LedgerSync] pull error: $e');
    } finally {
      _clearResolutionCaches();
    }
    final status =
        reachedEof ? SyncPullStatus.completed : SyncPullStatus.failed;

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
      status: status,
    );
  }

  Future<_RowOutcome> _processRow(Map<String, dynamic> row) async {
    final serverId = row['id'] as String?;
    if (serverId == null) return _RowOutcome.skipped;

    final payloadId = row['source_payload_id'] as String?;
    final serverUpdatedAt = row['updated_at'] as String?;
    // MALI-022 / 0068 — the server revision (CAS base). Null when the server
    // predates 0068 (the column is simply absent from the pulled row); stored as
    // NULL locally, which the push treats as fail-safe (guarded, not blind).
    final serverRevision = (row['revision'] as num?)?.toInt();
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

      // A local edit is awaiting push (MALI-009). If the server row moved past
      // the base version the edit was made against, that's a genuine
      // concurrent edit — surface a conflict WITHOUT touching the fields or
      // the base token (overwriting server_updated_at here would disarm the
      // push's optimistic check and silently pick a winner). If the server row
      // is still at our base, leave the row alone and let the push proceed.
      if (syncStatus == 'pending') {
        final baseToken = meta.readNullable<String>('server_updated_at');
        if (serverUpdatedAt != baseToken) {
          await _db.customStatement('''
            UPDATE transactions
            SET sync_status = 'conflict'
            WHERE id = ${sqlString(localId)};
          ''');
          return _RowOutcome.conflict;
        }
        return _RowOutcome.skipped;
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

      // The server row changed since we last saw it and there is no pending
      // local edit — apply the REMOTE FINANCIAL FIELDS, not just sync
      // metadata (MALI-009). Before this, an edit made on another device
      // never landed here, while the new server_updated_at was still
      // recorded — making the staleness permanent.
      final amount = (row['amount'] as num?)?.toDouble();
      final currency = row['currency'] as String?;
      final occurredAt = row['occurred_at'] as String?;
      final localCategoryId =
          await _localCategoryIdForKey(row['category_id'] as String?);
      // MALI-056n — converge to the remote canonical type/source/direction, not
      // a coarse approximation (symmetric with the push).
      final metadata = row['metadata'];
      final mappedType = LedgerPayloadCodec.typeFromPull(
        canonicalType: _canonicalMeta(metadata, 'canonical_type'),
        serverTransactionType: row['transaction_type'] as String? ?? 'unknown',
      );
      final mappedSource = LedgerPayloadCodec.sourceFromPull(
        canonicalSource: _canonicalMeta(metadata, 'canonical_source'),
        serverSource: row['source'] as String? ?? 'unknown',
      );
      final mappedDirection = LedgerPayloadCodec.directionFromPull(
        canonicalDirection: _canonicalMeta(metadata, 'canonical_direction'),
        type: mappedType,
      );
      final serverStatus = row['status'] as String?;
      final mappedStatus = switch (serverStatus) {
        'pending' => 'pending',
        'ignored' => 'ignored',
        _ => 'confirmed',
      };
      await _db.customStatement('''
        UPDATE transactions
        SET ${amount != null ? 'amount = $amount,' : ''}
            ${currency != null ? 'currency = ${sqlString(currency)},' : ''}
            raw_merchant = ${sqlNullableString(row['merchant'] as String?)},
            note = ${sqlNullableString(row['description'] as String?)},
            type = ${sqlString(mappedType.name)},
            source = ${sqlString(mappedSource.name)},
            direction = ${sqlString(mappedDirection.name)},
            status = ${sqlString(mappedStatus)},
            ${occurredAt != null ? 'occurred_at = ${sqlString(dateTimeToSql(DateTime.tryParse(occurredAt)?.toUtc() ?? DateTime.now().toUtc()))},' : ''}
            category_id = ${sqlNullableString(localCategoryId)},
            card_last4 = ${sqlNullableString(_last4FromMetadata(row['metadata']))},
            balance_after = ${sqlNullableNum((row['balance_after'] as num?)?.toDouble())},
            foreign_amount = ${sqlNullableNum((row['foreign_amount'] as num?)?.toDouble())},
            foreign_currency = ${sqlNullableString(row['foreign_currency'] as String?)},
            account_id = ${sqlNullableString(resolvedAccountId)},
            updated_at = ${sqlString(now)},
            server_id = ${sqlString(serverId)},
            synced_at = ${sqlString(now)},
            server_updated_at = ${sqlNullableString(serverUpdatedAt)},
            server_revision = ${sqlNullableNum(serverRevision)},
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

    await _transactionRepository.saveTransaction(
      transaction: entity,
      // Server stores the stable category KEY; saveTransaction resolves it
      // back to the local category id, so a pulled row keeps its category.
      categoryKey: row['category_id'] as String?,
      // MALI-029: reuse the pull's primed key→id snapshot so the shared
      // saveTransaction doesn't re-run `_categoryIdByKey` per imported row. Null
      // (key not in the local snapshot) falls back to the validating key path,
      // which seeds a known category exactly as before.
      resolvedCategoryId:
          await _localCategoryIdForKey(row['category_id'] as String?),
    );

    await _db.customStatement('''
      UPDATE transactions
      SET server_id = ${sqlString(serverId)},
          synced_at = ${sqlString(now)},
          server_updated_at = ${sqlNullableString(serverUpdatedAt)},
          server_revision = ${sqlNullableNum(serverRevision)},
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
    // MALI-056n — recover the EXACT client type/source/direction from the
    // canonical metadata (authoritative); fall back to the documented coarse
    // rule for older rows. Never silently turns an unknown/future type into
    // payment.
    final metadata = row['metadata'];
    final canonicalType = LedgerPayloadCodec.typeFromPull(
      canonicalType: _canonicalMeta(metadata, 'canonical_type'),
      serverTransactionType: row['transaction_type'] as String? ?? 'unknown',
    );
    return TransactionEntity(
      id: IdGenerator.next(),
      amount: amount,
      currency: currency,
      rawMerchant: row['merchant'] as String?,
      note: row['description'] as String?,
      type: canonicalType,
      source: LedgerPayloadCodec.sourceFromPull(
        canonicalSource: _canonicalMeta(metadata, 'canonical_source'),
        serverSource: row['source'] as String? ?? 'unknown',
      ),
      direction: LedgerPayloadCodec.directionFromPull(
        canonicalDirection: _canonicalMeta(metadata, 'canonical_direction'),
        type: canonicalType,
      ),
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
      final cache = _accountServerToLocal;
      if (cache != null) {
        final hit = cache[serverAccountId];
        if (hit != null) return hit;
      } else {
        final match = await _db
            .customSelect(
              'SELECT id FROM accounts '
              'WHERE server_id = ${sqlString(serverAccountId)} '
              'AND deleted_at IS NULL LIMIT 1;',
            )
            .getSingleOrNull();
        if (match != null) return match.read<String>('id');
      }
    }
    final localAccountId = row['local_account_id'] as String?;
    if (localAccountId != null && await _localAccountExists(localAccountId)) {
      return localAccountId;
    }
    return null;
  }

  /// Resolves the server's stable category KEY to the local category id
  /// (categories are keyed by stable strings across devices).
  Future<String?> _localCategoryIdForKey(String? key) async {
    if (key == null || key.isEmpty) return null;
    final cache = _categoryKeyToLocal;
    if (cache != null) return cache[key];
    final row = await _db
        .customSelect(
          'SELECT id FROM categories WHERE key = ${sqlString(key)} LIMIT 1;',
        )
        .getSingleOrNull();
    return row?.read<String>('id');
  }

  Future<bool> _localAccountExists(String id) async {
    final cache = _localAccountIds;
    if (cache != null) return cache.contains(id);
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

  /// MALI-056n — read a canonical string from the server `metadata` JSONB.
  String? _canonicalMeta(dynamic metadata, String key) =>
      metadata is Map ? metadata[key] as String? : null;
}

enum _RowOutcome { imported, updated, conflict, skipped }
