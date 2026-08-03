import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/backend/supabase_config.dart';
import '../../../core/sync/outbox_failure.dart';
import '../../../core/sync/sync_capabilities.dart';
import '../../../data/db/app_database.dart';
import '../../../data/db/sql_value_codec.dart';
import 'ledger_outbox_queue.dart';
import 'ledger_payload.dart';
import 'ledger_sync_engine.dart';

/// The acknowledgement columns a NON-CAS write (create/guarded update) reads
/// back. Includes the server `revision` only when the capability const is on —
/// the column exists on the server exactly when 0068 is deployed (same gate) —
/// so an OFF build never selects a column that isn't there.
const String _ackCols =
    kServerRevisionCas ? 'id, updated_at, revision' : 'id, updated_at';

/// The acknowledgement columns for the CAS branch. That branch runs only when
/// the capability is enabled (⇒ 0068 is deployed ⇒ `revision` exists), so it
/// always reads the revision back.
const String _casAckCols = 'id, updated_at, revision';

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
    bool revisionCasEnabled = kServerRevisionCas,
  })  : _db = db,
        _queue = queue,
        _isPushEnabled = isPushEnabled,
        _getAuthUserId = getAuthUserId ?? _defaultGetAuthUserId,
        _getClient = getClient ?? _defaultGetClient,
        _revisionCasEnabled = revisionCasEnabled;

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

  /// MALI-022 / 0068 — whether to use the atomic revision CAS. Defaults to the
  /// [kServerRevisionCas] capability const (OFF in production until 0068 is
  /// verified on staging); injectable so the ON path is testable.
  final bool _revisionCasEnabled;

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

    // MALI-056n — a payload written by a NEWER app version (after a downgrade)
    // must not be reinterpreted by this build; dead-letter it as an unsupported
    // schema so a later compatible upgrade can re-arm and apply it correctly.
    final version = (payload['payload_version'] as num?)?.toInt() ?? 1;
    if (version > kLedgerPayloadVersion) {
      await _queue.markFailed(
        item.id,
        'unsupported ledger payload version $version',
        OutboxFailureClass.unsupportedSchema,
      );
      return _PushOutcome.abandoned;
    }

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
          .select(_ackCols)
          .single();

      final serverId = response['id'] as String;
      await _attachServerId(
        item.transactionId,
        serverId,
        serverUpdatedAt: response['updated_at'] as String?,
        serverRevision: response['revision'] as int?,
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

    final expectedRevision = payload['server_revision'] as int?;
    try {
      // MALI-022 / 0068 — atomic compare-and-set when the capability is on AND
      // we have a base revision. The server updates only if `revision` still
      // matches; a zero-row result is a genuine conflict, not a lost update.
      if (_revisionCasEnabled && expectedRevision != null) {
        final updated = await _getClient()
            .from('user_transactions')
            .update(serverRow)
            .eq('id', serverId)
            .eq('revision', expectedRevision)
            .select(_casAckCols)
            .maybeSingle();
        if (updated == null) {
          // 0 rows matched → the server moved past our base revision.
          await _markConflict(item.transactionId);
          await _queue.markSuccess(item.id);
          return _PushOutcome.conflict;
        }
        await _attachServerId(
          item.transactionId,
          serverId,
          serverUpdatedAt: updated['updated_at'] as String?,
          serverRevision: updated['revision'] as int?,
        );
        await _queue.markSuccess(item.id);
        return _PushOutcome.pushed;
      }

      // Fail-safe guarded path (capability OFF, or revision unknown): compare
      // server updated_at with our last-known base. NEVER a blind overwrite.
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
    int? serverRevision,
  }) async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    await _db.customStatement('''
      UPDATE transactions
      SET server_id = ${sqlString(serverId)},
          synced_at = ${sqlString(now)},
          ${serverUpdatedAt != null ? 'server_updated_at = ${sqlString(serverUpdatedAt)},' : ''}
          ${serverRevision != null ? 'server_revision = $serverRevision,' : ''}
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
    // MALI-056n — prefer the versioned canonical type/direction when present, so
    // withdrawal/payment/unknown are mapped explicitly (not collapsed via the
    // lossy legacy debit/credit token). Old queued rows without a version fall
    // back to the legacy mapping below.
    final version = (payload['payload_version'] as num?)?.toInt() ?? 1;
    final canonicalType = payload['canonical_type'] as String?;
    final useCanonical = version >= 2 && canonicalType != null;
    final row = <String, dynamic>{
      'user_id': userId,
      'amount': payload['amount'],
      'currency': payload['currency'],
      'direction': useCanonical
          ? LedgerPayloadCodec.serverDirectionFor(
              canonicalType, payload['canonical_direction'] as String?)
          : switch (legacyType) {
              'credit' => 'credit',
              // A refund is money coming back — its direction is credit even
              // though it is not income (MALI-010).
              'refund' => 'credit',
              'debit' => 'debit',
              _ => 'unknown',
            },
      'transaction_type': useCanonical
          ? LedgerPayloadCodec.serverTransactionTypeFor(canonicalType)
          : switch (legacyType) {
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
    // MALI-056n — round-trip the EXACT client type/source/direction through
    // metadata (the coarse server columns cannot represent them), so a second
    // device recovers the precise meaning instead of a collapsed approximation.
    if (useCanonical) {
      metadata['payload_version'] = version;
      metadata['canonical_type'] = canonicalType;
      metadata['canonical_source'] = payload['canonical_source'];
      metadata['canonical_direction'] = payload['canonical_direction'];
    }
    if (metadata.isNotEmpty) row['metadata'] = metadata;
    return row;
  }
}

enum _PushOutcome { pushed, conflict, abandoned }
