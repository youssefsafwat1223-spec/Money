import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/backend/supabase_config.dart';
import '../../../core/sync/outbox_failure.dart';
import '../../../data/db/app_database.dart';
import '../../../data/db/sql_value_codec.dart';
import 'ledger_outbox_queue.dart';
import 'ledger_sync_engine.dart';

class LedgerPushResult {
  const LedgerPushResult({
    this.pushed = 0,
    this.conflicts = 0,
    this.failed = 0,
    this.abandoned = 0,
  });

  final int pushed;
  final int conflicts;
  final int failed;
  final int abandoned;
}

class LedgerPushService implements LedgerPushAdapter {
  LedgerPushService({
    required AppDatabase db,
    required LedgerOutboxQueue queue,
    required bool Function() isPushEnabled,
    Future<String?> Function()? getAuthUserId,
    SupabaseClient Function()? getClient,
  })  : _db = db,
        _queue = queue,
        _isPushEnabled = isPushEnabled,
        _getAuthUserId = getAuthUserId ?? _defaultGetAuthUserId,
        _getClient = getClient ?? _defaultGetClient;

  static Future<String?> _defaultGetAuthUserId() async {
    if (!SupabaseConfig.isConfigured) return null;
    try {
      return Supabase.instance.client.auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  static SupabaseClient _defaultGetClient() => Supabase.instance.client;

  final AppDatabase _db;
  final LedgerOutboxQueue _queue;
  final bool Function() _isPushEnabled;
  final Future<String?> Function() _getAuthUserId;
  final SupabaseClient Function() _getClient;

  @override
  Future<LedgerPushResult> push() async {
    if (!_isPushEnabled()) return const LedgerPushResult();

    final userId = await _getAuthUserId();
    if (userId == null) return const LedgerPushResult();

    final items = await _queue.pendingItems();
    if (items.isEmpty) return const LedgerPushResult();

    int pushed = 0;
    int conflicts = 0;
    int failed = 0;
    int abandoned = 0;

    for (final item in items) {
      try {
        final outcome = await _processItem(item, userId);
        switch (outcome) {
          case _PushOutcome.pushed:
            pushed++;
          case _PushOutcome.conflict:
            conflicts++;
          case _PushOutcome.abandoned:
            abandoned++;
        }
      } catch (e) {
        failed++;
        await _queue.markFailed(item.id, e.toString(), classifyOutboxError(e));
        if (kDebugMode) debugPrint('[LedgerPush] item error: $e');
      }
    }

    if (kDebugMode) {
      debugPrint(
        '[LedgerPush] done: pushed=$pushed conflicts=$conflicts '
        'failed=$failed abandoned=$abandoned',
      );
    }
    return LedgerPushResult(
      pushed: pushed,
      conflicts: conflicts,
      failed: failed,
      abandoned: abandoned,
    );
  }

  Future<_PushOutcome> _processItem(OutboxItem item, String userId) async {
    final payload = item.payloadJson;

    switch (item.operation) {
      case OutboxOperation.create:
        return _pushCreate(item, payload, userId);
      case OutboxOperation.update:
        return _pushUpdate(item, payload, userId);
      case OutboxOperation.delete:
        return _pushDelete(item, payload, userId);
    }
  }

  Future<_PushOutcome> _pushCreate(
    OutboxItem item,
    Map<String, dynamic> payload,
    String userId,
  ) async {
    final localId = payload['local_id'] as String? ?? item.transactionId;
    final serverRow = await _toServerRow(payload, userId);

    try {
      final response = await _getClient()
          .from('user_transactions')
          .upsert(
            {...serverRow, 'client_request_id': localId},
            onConflict: 'user_id,client_request_id',
          )
          .select('id, updated_at')
          .single();

      final serverId = response['id'] as String;
      await _attachServerId(
        item.transactionId,
        serverId,
        serverUpdatedAt: response['updated_at'] as String?,
      );
      await _queue.markSuccess(item.id);
      return _PushOutcome.pushed;
    } catch (e) {
      // Conflict detected by server (e.g. row already exists with newer updated_at).
      if (_isConflict(e)) {
        await _markConflict(item.transactionId);
        await _queue.markSuccess(item.id);
        return _PushOutcome.conflict;
      }
      rethrow;
    }
  }

  Future<_PushOutcome> _pushUpdate(
    OutboxItem item,
    Map<String, dynamic> payload,
    String userId,
  ) async {
    final localId = payload['local_id'] as String? ?? item.transactionId;
    String? serverId = payload['server_id'] as String?;

    // If server_id unknown, try to find it via the stable client request id.
    serverId ??= await _findServerId(localId, userId);

    if (serverId == null) {
      // Row not on server yet — treat as create.
      return _pushCreate(item, payload, userId);
    }

    final serverRow = await _toServerRow(payload, userId);
    // Never overwrite source on existing server rows — the server already has
    // the authoritative source (e.g. 'ios_shortcut' from the relay dual-write).
    // Relay-imported transactions only appear in the outbox as updates/deletes,
    // never as creates, so their server source must be preserved.
    serverRow.remove('source');

    // Conflict check: compare server updated_at with our last-known server_updated_at.
    try {
      final existing = await _getClient()
          .from('user_transactions')
          .select('updated_at')
          .eq('id', serverId)
          .maybeSingle();

      if (existing != null) {
        final localKnown =
            DateTime.tryParse(payload['server_updated_at'] as String? ?? '');
        final serverTs = DateTime.tryParse(
          existing['updated_at'] as String? ?? '',
        );
        if (localKnown != null &&
            serverTs != null &&
            serverTs.isAfter(localKnown)) {
          await _markConflict(item.transactionId);
          await _queue.markSuccess(item.id);
          return _PushOutcome.conflict;
        }
      }

      final updated = await _getClient()
          .from('user_transactions')
          .update(serverRow)
          .eq('id', serverId)
          .select('updated_at')
          .maybeSingle();

      await _attachServerId(
        item.transactionId,
        serverId,
        // Store the version our update produced — the next edit's outbox
        // payload carries it as the base token (MALI-009).
        serverUpdatedAt: updated?['updated_at'] as String?,
      );
      await _queue.markSuccess(item.id);
      return _PushOutcome.pushed;
    } catch (e) {
      if (_isConflict(e)) {
        await _markConflict(item.transactionId);
        await _queue.markSuccess(item.id);
        return _PushOutcome.conflict;
      }
      rethrow;
    }
  }

  Future<_PushOutcome> _pushDelete(
    OutboxItem item,
    Map<String, dynamic> payload,
    String userId,
  ) async {
    final localId = payload['local_id'] as String? ?? item.transactionId;
    String? serverId = payload['server_id'] as String?;
    serverId ??= await _findServerId(localId, userId);

    if (serverId == null) {
      // Row never reached the server; just remove outbox item.
      await _queue.markSuccess(item.id);
      return _PushOutcome.pushed;
    }

    await _getClient()
        .from('user_transactions')
        .update({'deleted_at': DateTime.now().toUtc().toIso8601String()}).eq(
      'id',
      serverId,
    );

    await _queue.markSuccess(item.id);
    return _PushOutcome.pushed;
  }

  Future<String?> _findServerId(String localId, String userId) async {
    try {
      final row = await _getClient()
          .from('user_transactions')
          .select('id')
          .eq('user_id', userId)
          .eq('client_request_id', localId)
          .maybeSingle();
      return row?['id'] as String?;
    } catch (_) {
      return null;
    }
  }

  Future<void> _attachServerId(
    String transactionId,
    String serverId, {
    String? serverUpdatedAt,
  }) async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    await _db.customStatement('''
      UPDATE transactions
      SET server_id = ${sqlString(serverId)},
          synced_at = ${sqlString(now)},
          ${serverUpdatedAt != null ? 'server_updated_at = ${sqlString(serverUpdatedAt)},' : ''}
          sync_status = 'synced'
      WHERE id = ${sqlString(transactionId)};
    ''');
  }

  Future<void> _markConflict(String transactionId) async {
    await _db.customStatement('''
      UPDATE transactions
      SET sync_status = 'conflict'
      WHERE id = ${sqlString(transactionId)};
    ''');
  }

  static bool _isConflict(Object e) {
    final msg = e.toString().toLowerCase();
    return msg.contains('409') ||
        msg.contains('conflict') ||
        msg.contains('duplicate');
  }

  Future<Map<String, dynamic>> _toServerRow(
    Map<String, dynamic> payload,
    String userId,
  ) async {
    final legacyType = payload['type'] as String? ?? 'debit';
    final row = <String, dynamic>{
      'user_id': userId,
      'amount': payload['amount'],
      'currency': payload['currency'],
      'direction': switch (legacyType) {
        'credit' => 'credit',
        // A refund is money coming back — its direction is credit even
        // though it is not income (MALI-010).
        'refund' => 'credit',
        'debit' => 'debit',
        _ => 'unknown',
      },
      'transaction_type': switch (legacyType) {
        'credit' => 'income',
        'transfer' => 'transfer',
        'refund' => 'refund',
        'debit' => 'expense',
        _ => 'unknown',
      },
      // source is present for create operations; absent for update operations.
      // The fallback 'manual' is only reached when an update is redirected to
      // a create (_pushUpdate → _pushCreate) because the row is not on the
      // server yet (dual-write was OFF). _pushUpdate strips 'source' before
      // patching, so this fallback never overwrites an existing server source.
      'source': payload['source'] ?? 'manual',
      'occurred_at': payload['occurred_at'],
    };
    if (payload['merchant'] != null) row['merchant'] = payload['merchant'];
    if (payload['note'] != null) row['description'] = payload['note'];
    // Round-trip the confirmation state (MALI-010). Server check constraint
    // accepts confirmed/pending/ignored (migration 0029).
    final status = payload['status'] as String?;
    if (status == 'confirmed' || status == 'pending' || status == 'ignored') {
      row['status'] = status;
    }
    final localAccountId = payload['account_id'] as String?;
    if (localAccountId != null) {
      row['local_account_id'] = localAccountId;
      final account = await _db
          .customSelect(
            'SELECT server_id FROM accounts '
            'WHERE id = ${sqlString(localAccountId)} LIMIT 1;',
          )
          .getSingleOrNull();
      final serverAccountId = account?.readNullable<String>('server_id');
      if (serverAccountId != null) {
        row['server_account_id'] = serverAccountId;
      }
    }
    if (payload['confidence'] != null) {
      row['confidence'] = payload['confidence'];
    }
    // Category: the server stores the stable category KEY, not the local UUID.
    final localCategoryId = payload['category_id'] as String?;
    if (localCategoryId != null) {
      final cat = await _db
          .customSelect(
            'SELECT key FROM categories '
            'WHERE id = ${sqlString(localCategoryId)} LIMIT 1;',
          )
          .getSingleOrNull();
      final key = cat?.readNullable<String>('key');
      if (key != null) row['category_id'] = key;
    }
    if (payload['balance_after'] != null) {
      row['balance_after'] = payload['balance_after'];
    }
    if (payload['foreign_amount'] != null) {
      row['foreign_amount'] = payload['foreign_amount'];
    }
    if (payload['foreign_currency'] != null) {
      row['foreign_currency'] = payload['foreign_currency'];
    }
    // Metadata mirrors the backfill so card linkage + provenance survive the
    // round-trip (the server has no dedicated card_last4 column — last4 lives
    // in metadata). Only written when non-empty so an update never blanks
    // server metadata it has nothing to say about.
    final metadata = <String, dynamic>{};
    if (payload['card_last4'] != null) {
      metadata['last4'] = payload['card_last4'];
    }
    if (payload['source'] != null) {
      metadata['transaction_source'] = payload['source'];
    }
    if (metadata.isNotEmpty) row['metadata'] = metadata;
    return row;
  }
}

enum _PushOutcome { pushed, conflict, abandoned }
