import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/backend/supabase_config.dart';
import '../../../core/sync/guarded_mutation.dart';
import '../../../core/sync/outbox_failure.dart';
import '../../../core/sync/sync_capabilities.dart';
import '../../../data/db/app_database.dart';
import '../../../data/db/planning_cutover.dart';
import '../../../data/db/sql_value_codec.dart';
import '../../../data/sync/exact_transport_capability.dart';
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
    this.parked = 0,
  });

  final int pushed;
  final int conflicts;
  final int failed;
  final int abandoned;

  /// MALI-026 (B8-2.10 §8): money rows held for unverified exact push transport.
  final int parked;
}

class LedgerPushService implements LedgerPushAdapter {
  LedgerPushService({
    required AppDatabase db,
    required LedgerOutboxQueue queue,
    required bool Function() isPushEnabled,
    Future<String?> Function()? getAuthUserId,
    SupabaseClient Function()? getClient,
    bool revisionCasEnabled = kServerRevisionCas,
    // MALI-026 (B8-2.10 §8/§9): the money-authority mode and exact PUSH capability.
    // Both default so v29 (legacy + unknown) never parks — current behavior is
    // unchanged. Only canonical mode with an unverified push capability parks.
    PlanningCutoverCoordinator coordinator =
        const SchemaV29PlanningCutoverCoordinator(),
    ExactTransportCapability Function() pushCapability = _defaultPushCapability,
    /// C-3 — consulted at the moment of egress; defaults to DENY.
    Future<bool> Function()? mayEgress,
  })  : _db = db,
        _queue = queue,
        _isPushEnabled = isPushEnabled,
        _getAuthUserId = getAuthUserId ?? _defaultGetAuthUserId,
        _getClient = getClient ?? _defaultGetClient,
        _revisionCasEnabled = revisionCasEnabled,
        _coordinator = coordinator,
        _pushCapability = pushCapability,
        _mayEgress = mayEgress ?? _denyEgressByDefault;

  static ExactTransportCapability _defaultPushCapability() =>
      ExactTransportCapability.unknown;

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
  final Future<bool> Function() _mayEgress;
  final bool Function() _isPushEnabled;
  final Future<String?> Function() _getAuthUserId;
  final SupabaseClient Function() _getClient;

  /// MALI-022 / 0068 — whether to use the atomic revision CAS. Defaults to the
  /// [kServerRevisionCas] capability const (OFF in production until 0068 is
  /// verified on staging); injectable so the ON path is testable.
  final bool _revisionCasEnabled;

  final PlanningCutoverCoordinator _coordinator;
  final ExactTransportCapability Function() _pushCapability;

  static Future<bool> _denyEgressByDefault() async => false;

  @override
  Future<LedgerPushResult> push() async {
    // C-3 — transactions are money. Without cloud consent they stay on device.
    if (!await _mayEgress()) return const LedgerPushResult();
    if (!_isPushEnabled()) return const LedgerPushResult();

    final userId = await _getAuthUserId();
    if (userId == null) return const LedgerPushResult();

    // MALI-026 (B8-2.10 §9): once exact push transport is verified, re-arm any
    // rows parked while it was unverified — the SAME durable rows drain now. A
    // no-op today (nothing is ever parked while the capability is unknown/legacy).
    if (_pushCapability() == ExactTransportCapability.verifiedExact) {
      await _queue.reArmParked();
    }

    final items = await _queue.pendingItems();
    if (items.isEmpty) return const LedgerPushResult();

    int pushed = 0;
    int conflicts = 0;
    int failed = 0;
    int abandoned = 0;
    int parked = 0;

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
          case _PushOutcome.parked:
            // Held durably; not sent, not synced, not a failure/retry.
            parked++;
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
      parked: parked,
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

    // MALI-026 (B8-2.10 §8): park money-bearing writes whose exact push transport
    // is unverified BEFORE any network send. Deletes carry no money and are never
    // parked. Legacy (v29) never parks — shouldParkExactMoneyWrite is false for it.
    if (item.operation != OutboxOperation.delete &&
        shouldParkExactMoneyWrite(
          cutoverState: _coordinator.state(),
          pushCapability: _pushCapability(),
        )) {
      await _queue.park(item.id, exactMoneyTransportUnverifiedReason);
      return _PushOutcome.parked;
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
        // MALI-026 (Phase-9M): decode the LIST (0/1/>1); a 0-row CAS is the
        // conflict branch, not a PGRST116 throw.
        final rows = await _getClient()
            .from('user_transactions')
            .update(serverRow)
            .eq('id', serverId)
            .eq('revision', expectedRevision)
            .select(_casAckCols);
        final updated = guardedAck(rows, 'ledger.casUpdate');
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

      // C-6 — fail-safe guarded path (capability OFF, or revision unknown).
      //
      // This used to SELECT the server's updated_at, compare it, then issue a
      // blind write by id. Two round-trips, so a remote write landing between
      // them was silently clobbered: the guard had passed against a value that
      // was no longer true when the write executed.
      //
      // The predicate now travels WITH the write, exactly as the tombstone
      // branch below already did, so the database enforces it and 0 affected
      // rows IS the conflict signal.
      final base = payload['server_updated_at'] as String?;
      final rows = base != null
          ? await _getClient()
              .from('user_transactions')
              .update(serverRow)
              .eq('id', serverId)
              .eq('updated_at', base)
              .select('updated_at')
          // No base to guard against (first push of an adopted row): a targeted
          // update by id is the strongest guard available.
          : await _getClient()
              .from('user_transactions')
              .update(serverRow)
              .eq('id', serverId)
              .select('updated_at');
      final updated = guardedAck(rows, 'ledger.atomicGuardedUpdate');
      if (updated == null) {
        // 0 rows → either the row vanished or another writer moved it past our
        // base. Both are conflicts; the guard no longer needs to distinguish
        // them with a second read.
        await _markConflict(item.transactionId);
        await _queue.markSuccess(item.id);
        return _PushOutcome.conflict;
      }
      await _attachServerId(
        item.transactionId,
        serverId,
        // Store the version our update produced — the next edit's outbox
        // payload carries it as the base token (MALI-009).
        serverUpdatedAt: updated['updated_at'] as String?,
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

    final deletedAt = DateTime.now().toUtc().toIso8601String();
    final expectedRevision = payload['server_revision'] as int?;
    try {
      // MALI-022 / 0068 (Phase-9K): the tombstone is GUARDED, never the old
      // unconditional id-only overwrite. CAS on the base revision when known;
      // otherwise an optimistic updated_at compare. A zero-row result is
      // classified below — a stale delete can never clobber a newer update.
      if (_revisionCasEnabled && expectedRevision != null) {
        // MALI-026 (Phase-9M): decode the LIST (0/1/>1); a 0-row tombstone flows
        // to the classifier, not a PGRST116 throw.
        final rows = await _getClient()
            .from('user_transactions')
            .update({'deleted_at': deletedAt})
            .eq('id', serverId)
            .eq('revision', expectedRevision)
            .select(_casAckCols);
        final ack = guardedAck(rows, 'ledger.casTombstone');
        if (ack != null) {
          await _queue.markSuccess(item.id);
          return _PushOutcome.pushed;
        }
        return _resolveDeleteConflict(item, serverId);
      }

      // Never id-only: guard on the last-known updated_at, or (when unknown) on
      // the row not already being tombstoned. Each branch is a single chained
      // statement so the guard predicate always travels with the deleted_at write.
      final base = payload['server_updated_at'] as String?;
      final rows = base != null
          ? await _getClient()
              .from('user_transactions')
              .update({'deleted_at': deletedAt})
              .eq('id', serverId)
              .eq('updated_at', base)
              .select('id, updated_at')
          : await _getClient()
              .from('user_transactions')
              .update({'deleted_at': deletedAt})
              .eq('id', serverId)
              .isFilter('deleted_at', null)
              .select('id, updated_at');
      final ack = guardedAck(rows, 'ledger.guardedTombstone');
      if (ack != null) {
        await _queue.markSuccess(item.id);
        return _PushOutcome.pushed;
      }
      return _resolveDeleteConflict(item, serverId);
    } catch (e) {
      if (_isConflict(e)) {
        await _markConflict(item.transactionId);
        await _queue.markSuccess(item.id);
        return _PushOutcome.conflict;
      }
      rethrow;
    }
  }

  /// A guarded tombstone matched zero rows. Classify (Phase-9K §5):
  ///   A. already tombstoned  → the delete already converged → idempotent success
  ///   B. still live, advanced → a newer accepted update → conflict, do NOT delete
  ///   C. absent               → fail-closed → conflict
  /// On B/C the server row (its newer update) is untouched — the next pull
  /// re-materialises the transaction, so the update is never lost. Transactions
  /// soft-delete locally as status='ignored' (the row persists), so the conflict
  /// flag is durable and recoverable via keep-mine / keep-theirs.
  Future<_PushOutcome> _resolveDeleteConflict(
    OutboxItem item,
    String serverId,
  ) async {
    final state = await _getClient()
        .from('user_transactions')
        .select('deleted_at')
        .eq('id', serverId)
        .maybeSingle();
    if (state != null && state['deleted_at'] != null) {
      await _queue.markSuccess(item.id); // A
      return _PushOutcome.pushed;
    }
    await _markConflict(item.transactionId); // B (live) or C (absent)
    await _queue.markSuccess(item.id);
    return _PushOutcome.conflict;
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

enum _PushOutcome { pushed, conflict, abandoned, parked }
