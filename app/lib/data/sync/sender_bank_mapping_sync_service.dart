import 'dart:async';
import 'dart:convert';
import '../../core/session/account_fence_authority.dart';
import '../../core/session/admission_authority.dart';
import '../../core/session/app_session.dart';
import '../../core/sync/account_fence_retry.dart';
import '../../core/sync/sync_health.dart';
import 'package:drift/drift.dart' show QueryRow;
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import '../../core/sync/outbox_failure.dart';
import '../db/app_database.dart';
import '../db/sql_value_codec.dart';
import 'seq_pull.dart';
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
    final context = Zone.current[_senderRemoteKey] as _SenderRemoteContext?;
    context?.invocation.requireCurrent();
    if (context != null && jsonEncode(rows) != jsonEncode(context.payload)) {
      throw const SenderMappingDeliveryStopped(SenderMappingDeliveryStopReason.provenance);
    }
    // Synchronous factory and representation parsing are outside origin tagging.
    final response = _client.from(_table)
        .upsert(rows, onConflict: 'user_id,normalized_sender_id').select();
    final List<Map<String, dynamic>> result;
    try {
      result = await response;
    } on supabase.PostgrestException catch (error) {
      if (context != null && decodeSenderMappingAccountDenial(error) != null) {
        throw _SenderMutationRefusal(context, error);
      }
      rethrow;
    }
    return result;
  }
}

class SenderBankMappingSyncService {
  SenderBankMappingSyncService({
    required AppDatabase db,
    required SenderMappingRemoteStore remoteStore,
    required String? Function() currentUserId,
    /// C-3 — consulted at the moment of egress. Defaults to DENY: a caller that
    /// forgets to pass it gets no network, which is the failure direction that
    /// cannot leak. The previous pattern (default `() => true`) is exactly how
    /// backup upload shipped ungated.
    Future<bool> Function()? mayEgress,
    int pageSize = 200,
    SyncHealth? health,
    AccountFenceRetry? fenceRetry,
    /// WP-4: sequence pull gate. Null keeps the legacy timestamp pull.
    SeqPullGate? seqGate,
  })  : assert(pageSize > 0),
        _seqGate = seqGate,
        _health = health,
        _fenceRetry = fenceRetry ?? AccountFenceRetry(),
        _db = db,
        _remoteStore = remoteStore,
        _currentUserId = currentUserId,
        _mayEgress = mayEgress ?? _denyByDefault,
        _pageSize = pageSize;

  static Future<bool> _denyByDefault() async => false;

  final AppDatabase _db;
  final SenderMappingRemoteStore _remoteStore;
  final String? Function() _currentUserId;
  final Future<bool> Function() _mayEgress;
  final SyncHealth? _health;
  final int _pageSize;
  final SeqPullGate? _seqGate;
  final AccountFenceRetry _fenceRetry;
  bool _busy = false;

  static const _cursorKey = 'sender_bank_mappings';

  Future<SenderMappingSyncResult> sync() => syncWithPhase(SyncPhaseBinding());

  Future<SenderMappingSyncResult> syncWithPhase(SyncPhaseBinding phase,
      {AdmissionAuthority? originalAuthority}) async {
    return _bound(phase, originalAuthority, (invocation, allowed) async {
      if (!allowed) {
        await _health?.runPhase(SyncDomain.senderMappings, SyncDirection.push,
            () async => phase.noteConsentBlocked(_health), binding: phase, rethrowErrors: true);
        return const SenderMappingSyncResult();
      }
      final pushed = _health == null ? await _push(invocation, phase) :
          (await _health.runPhase(SyncDomain.senderMappings, SyncDirection.push,
              () => _push(invocation, phase), binding: phase, rethrowErrors: true))!;
      invocation.requireCurrent();
      final pullPhase = phase.forNextPhase();
      final pulled = _health == null ? await pull(invocation.uid) :
          (await _health.runPhase(SyncDomain.senderMappings, SyncDirection.pull,
              () => pull(invocation.uid), binding: pullPhase, rethrowErrors: true))!;
      invocation.requireCurrent();
      return SenderMappingSyncResult(imported: pulled.imported, updated: pulled.updated,
          tombstoned: pulled.tombstoned, pushed: pushed.$1, failed: pushed.$2);
    });
  }

  Future<(int, int)> push([String? forUserId]) async {
    final phase = SyncPhaseBinding();
    if (_health == null) return pushWithPhase(phase, forUserId: forUserId);
    return (await _health.runPhase(SyncDomain.senderMappings, SyncDirection.push,
        () => pushWithPhase(phase, forUserId: forUserId), binding: phase, rethrowErrors: true))!;
  }

  Future<(int, int)> pushWithPhase(SyncPhaseBinding phase, {String? forUserId,
      AdmissionAuthority? originalAuthority}) => _bound(phase, originalAuthority, (invocation, allowed) async {
    if (forUserId != null && forUserId != invocation.uid) {
      throw const SenderMappingDeliveryStopped(SenderMappingDeliveryStopReason.provenance);
    }
    if (!allowed) { phase.noteConsentBlocked(_health); return (0, 0); }
    return _push(invocation, phase);
  });

  Future<T> _bound<T>(SyncPhaseBinding phase, AdmissionAuthority? received,
      Future<T> Function(_SenderInvocation, bool) work) async {
    if (_busy) throw const SenderMappingDeliveryStopped(SenderMappingDeliveryStopReason.overlap);
    _busy = true;
    final inherited = phase.isBound ? phase : null;
    void supplied() {
      if ((inherited != null && (!inherited.isCurrent || !identical(inherited.database, _db))) ||
          (received != null && (!received.isCurrent ||
            AppSession.instance.captureLocalWorkAuthority()?.epoch != received.epoch))) {
        throw const SenderMappingDeliveryStopped(SenderMappingDeliveryStopReason.stale);
      }
    }
    try {
      supplied();
      final authority = AccountFenceAuthority.shared;
      final handle = await authority.captureForDatabase(AppSession.instance, _db);
      supplied();
      if (handle == null) throw const SenderMappingDeliveryStopped(SenderMappingDeliveryStopReason.unbound);
      final invocation = _SenderInvocation(authority, handle, _db, inherited, received, _currentUserId);
      if (!phase.isBound) phase.bind(invocation);
      invocation.requireCurrent();
      if (_currentUserId() != invocation.uid) {
        throw const SenderMappingDeliveryStopped(SenderMappingDeliveryStopReason.stale);
      }
      final bool allowed;
      try { allowed = await _mayEgress(); }
      catch (error, stack) {
        invocation.requireCurrent();
        if (_health != null) {
          await _health.runPhase<void>(SyncDomain.senderMappings, SyncDirection.push,
              () => Future<void>.error(error, stack), binding: phase, rethrowErrors: true);
        }
        Error.throwWithStackTrace(error, stack);
      }
      invocation.requireCurrent();
      return await work(invocation, allowed);
    } on StaleAdmissionException {
      throw const SenderMappingDeliveryStopped(SenderMappingDeliveryStopReason.stale);
    } finally { _busy = false; }
  }

  Future<(int, int)> _push(_SenderInvocation invocation, SyncPhaseBinding phase) async {
    invocation.requireCurrent();
    final nowSql = dateTimeToSql(_fenceRetry.clock().toUtc());
    final pending = await invocation.runLocal(() => _db.transaction(() => _db.customSelect(
      "SELECT * FROM sender_bank_mappings WHERE sync_status IN ('pending', 'failed') "
      'AND sync_permanent=0 AND (sync_next_retry_at IS NULL OR sync_next_retry_at<=${sqlString(nowSql)}) '
      "AND (deleted_at IS NOT NULL OR status IN ('confirmed','rejected'));",
    ).get()));
    invocation.requireCurrent();
    if (pending.isEmpty) return (0, 0);
    List<Map<String, dynamic>> stored;
    try {
      stored = await _send(invocation, pending);
    } on _SenderReceiptFailure catch (error) {
      phase.noteFailure(_health, error); return (0, 0);
    } on AccountFenceDeliveryCancellation { rethrow; }
    on _SenderRemoteOrdinary catch (failure) {
      final error = failure.error;
      if (error is supabase.PostgrestException && error.code == '55P03') {
        await _cooldown(invocation, pending); phase.noteFailure(_health, error); return (0, 0);
      }
      return _pushPerRow(invocation, phase, pending);
    }
    // Local receipt/ACK exceptions never fall into network replay.
    final tokens = _validateReceipt(stored, pending, invocation.uid);
    try {
      await _ack(invocation, pending, tokens);
    } on AccountFenceDeliveryCancellation { rethrow; }
    catch (error) { invocation.requireCurrent(); phase.noteFailure(_health, error); return (pending.length, 0); }
    return (pending.length, 0);
  }

  Future<List<Map<String, dynamic>>> _send(_SenderInvocation invocation, List<QueryRow> pending) async {
    invocation.requireCurrent();
    final intent = await invocation.authority.captureSenderMappingIntent(invocation.handle, _db,
        pending.map((row) => row.data).toList());
    invocation.requireCurrent();
    if (intent == null) throw const SenderMappingDeliveryStopped(SenderMappingDeliveryStopReason.provenance);
    final payload = List<Map<String, dynamic>>.unmodifiable(pending.map((row) =>
        Map<String, dynamic>.unmodifiable(_toServerRow(row, invocation.uid))));
    final context = _SenderRemoteContext(invocation, intent, payload);
    Object? remoteFailure;
    StackTrace? remoteStack;
    Future<List<Map<String, dynamic>>> dispatch() {
      invocation.requireCurrent();
      final Future<List<Map<String, dynamic>>> actual;
      try {
        actual = runZoned(() => _remoteStore.upsert(payload),
            zoneValues: {_senderRemoteKey: context});
      } catch (error, stack) {
        remoteFailure = error;
        remoteStack = stack;
        rethrow;
      }
      return actual.catchError((Object error, StackTrace stack) {
        remoteFailure = error;
        remoteStack = stack;
        Error.throwWithStackTrace(error, stack);
      });
    }
    try {
      final stored = await _fenceRetry.runItem(isCurrent: () {
        remoteFailure = null;
        remoteStack = null;
        return _retryCurrent(invocation, pending);
      }, body: () => retryAccountFenceMutation(dispatch));
      invocation.requireCurrent();
      // Parse/validate OUTSIDE the remote-failure fallback boundary.
      try { _validateReceipt(stored, pending, invocation.uid); }
      catch (_) { throw const _SenderReceiptFailure(); }
      return stored;
    } on _SenderMutationRefusal catch (refusal) {
      if (!identical(refusal.context, context)) {
        throw const SenderMappingDeliveryStopped(SenderMappingDeliveryStopReason.provenance);
      }
      final result = await invocation.authority.acceptSenderMappingDenial(invocation.handle, _db, intent,
          decodeSenderMappingAccountDenial(refusal.raw)!);
      throw SenderMappingDeliveryStopped(SenderMappingDeliveryStopReason.denial,
          accepted: result.accepted, complete: result.complete);
    } on AccountFenceDeliveryCancellation { rethrow; }
    on TypeError { throw const _SenderReceiptFailure(); }
    on FormatException { throw const _SenderReceiptFailure(); }
    on AccountFenceRetryStopped {
      throw const SenderMappingDeliveryStopped(SenderMappingDeliveryStopReason.stale);
    } catch (error) {
      if (decodeSenderMappingAccountDenial(error) != null) {
        throw const SenderMappingDeliveryStopped(SenderMappingDeliveryStopReason.nonMutationRefusal);
      }
      invocation.requireCurrent();
      if (identical(error, remoteFailure)) {
        throw _SenderRemoteOrdinary(error, remoteStack!);
      }
      rethrow;
    }
  }

  Future<bool> _retryCurrent(_SenderInvocation invocation, List<QueryRow> rows) async {
    invocation.requireCurrent();
    if (_currentUserId() != invocation.uid) return false;
    final allowed = await _mayEgress();
    invocation.requireCurrent();
    if (!allowed) return false;
    final exact = await invocation.runLocal(() => _db.transaction(() async {
      for (final row in rows) { if (!await _matches(row)) return false; }
      return true;
    }));
    invocation.requireCurrent(); return exact;
  }

  Map<String, String> _validateReceipt(List<Map<String, dynamic>> stored, List<QueryRow> pending, String uid) {
    final keys = pending.map((row) => row.read<String>('normalized_sender_id')).toSet();
    final result = <String, String>{};
    for (final row in stored) {
      final key = row['normalized_sender_id']; final id = row['id']; final stamp = row['updated_at'];
      if (key is! String || !keys.contains(key) || result.containsKey(key) ||
          id is! String || id.isEmpty || stamp is! String || DateTime.tryParse(stamp) == null ||
          (row.containsKey('user_id') && row['user_id'] != uid)) {
        throw const _SenderReceiptFailure();
      }
      result[key] = stamp;
    }
    if (result.length != keys.length) throw const _SenderReceiptFailure();
    return result;
  }

  Future<bool> _matches(QueryRow snapshot) async {
    final actual = await _db.customSelect('SELECT * FROM sender_bank_mappings '
        'WHERE id=${sqlString(snapshot.read<String>('id'))};').getSingleOrNull();
    return actual != null && mapEquals(actual.data, snapshot.data);
  }

  Future<void> _ack(_SenderInvocation invocation, List<QueryRow> rows, Map<String, String> tokens) async {
    await invocation.runLocal(() => _db.transaction(() async {
      for (final row in rows) {
        if (await _matches(row)) {
          await _markSynced(row.read<String>('id'),
              tokens[row.read<String>('normalized_sender_id')], pushedUpdatedAt: row.read<String>('updated_at'));
        }
      }
    }));
    invocation.requireCurrent();
  }

  Future<void> _cooldown(_SenderInvocation invocation, List<QueryRow> rows) async {
    final next = dateTimeToSql(_fenceRetry.clock().toUtc().add(_fenceRetry.cooldown));
    await invocation.runLocal(() => _db.transaction(() async {
      for (final row in rows) {
        if (await _matches(row)) {
          await _db.customStatement('UPDATE sender_bank_mappings '
              'SET sync_next_retry_at=${sqlString(next)} WHERE id=${sqlString(row.read<String>('id'))};');
        }
      }
    }));
    invocation.requireCurrent();
  }

  Future<(int, int)> _pushPerRow(_SenderInvocation invocation, SyncPhaseBinding phase, List<QueryRow> pending) async {
    var pushed = 0, failed = 0;
    for (final row in pending) {
      invocation.requireCurrent();
      if (!await invocation.runLocal(() => _db.transaction(() => _matches(row)))) continue;
      List<Map<String, dynamic>> stored;
      try { stored = await _send(invocation, [row]); }
      on _SenderReceiptFailure catch (error) { phase.noteFailure(_health, error); continue; }
      on AccountFenceDeliveryCancellation { rethrow; }
      on _SenderRemoteOrdinary catch (failure) {
        final error = failure.error;
        invocation.requireCurrent();
        if (error is supabase.PostgrestException && error.code == '55P03') {
          await _cooldown(invocation, [row]); phase.noteFailure(_health, error); return (pushed, failed);
        }
        final matched = await invocation.runLocal(() => _db.transaction(() async {
          if (!await _matches(row)) return false;
          await _markFailed(row.read<String>('id'), classifyOutboxError(error)); return true;
        }));
        invocation.requireCurrent();
        if (matched) { phase.noteFailure(_health, error); failed++; }
        continue;
      }
      final tokens = _validateReceipt(stored, [row], invocation.uid);
      pushed++; // Complete remote acceptance is independent of local ACK success.
      try { await _ack(invocation, [row], tokens); }
      on AccountFenceDeliveryCancellation { rethrow; }
      catch (error) { invocation.requireCurrent(); phase.noteFailure(_health, error); continue; }
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
    // Gated independently of sync(); see push().
    if (!await _mayEgress()) {
      _health?.noteConsentBlocked(SyncDomain.senderMappings);
      return (imported: 0, updated: 0, tombstoned: 0);
    }

    var imported = 0;
    var updated = 0;
    var tombstoned = 0;
    try {
      // WP-4: protocol selection.
      final plan = _seqGate != null
          ? await _seqGate.plan(userId)
          : const SeqPlan(SeqMode.legacy);
      if (plan.mode == SeqMode.stopped) {
        return (imported: 0, updated: 0, tombstoned: 0);
      }
      final useSeq = plan.mode == SeqMode.seq;
      var cursor = await readSyncCursor(_db, _cursorKey);
      var seqCursor = useSeq ? await readSeqCursor(_db, userId, _cursorKey) : 0;
      var reachedEof = useSeq && plan.isIdle(seqCursor);
      while (!reachedEof) {
        final rows = useSeq
            ? await _seqGate!.fetch(
                table: 'sender_bank_mappings',
                userId: userId,
                afterSeq: seqCursor,
                limit: _pageSize,
              )
            : await _remoteStore.fetchRows(after: cursor, limit: _pageSize);
        if (rows.isEmpty) {
          reachedEof = true;
          break;
        }

        final nextSeq = useSeq ? nextSeqOf(rows, seqCursor) : 0;
        final nextCursor = useSeq ? cursor : SyncCursor.fromServerRow(rows.last);
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
          if (useSeq) {
            await writeSeqCursor(_db, userId, _cursorKey, nextSeq);
          } else {
            await writeSyncCursor(_db, _cursorKey, nextCursor);
          }
          return (pi, pu, pt);
        });
        imported += page.$1;
        updated += page.$2;
        tombstoned += page.$3;
        cursor = nextCursor;
        if (useSeq) seqCursor = nextSeq;
        if (rows.length < _pageSize) {
          reachedEof = true;
          break;
        }
      }
      if (useSeq && reachedEof) {
        await _seqGate!.markCaughtUp(userId, _cursorKey, seqCursor, plan);
      }
    } on AccountFenceDeliveryCancellation { rethrow; } catch (e) {
      _health?.noteFailure(SyncDomain.senderMappings, e);
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
      // Never overwrite a locally pending OR failed change on pull — a pending
      // one is pushed and wins by the server-authoritative timestamp; a failed
      // one still holds the user's unsynced intent (G10).
      if (_isUnsettledLocal(existing.readNullable<String>('sync_status'))) {
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
          accepted_by = ${sqlNullableString(row['accepted_by'] as String?)},
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
        server_updated_at, sync_status, deleted_at, accepted_by
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
        NULL,
        ${sqlNullableString(row['accepted_by'] as String?)}
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
    if (_isUnsettledLocal(existing.readNullable<String>('sync_status'))) {
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
    final acceptedBy = read('accepted_by');
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
      // Only when set, so a server without the column still accepts
      // legacy/user rows.
      if (acceptedBy != null) 'accepted_by': acceptedBy,
      // updated_at is deliberately omitted — server-authoritative (0069).
    };
  }

  /// Called inside the tracked transaction only after the full persisted row
  /// matches the handed snapshot. The timestamp predicate is an additional
  /// guard; it is not a distinct local edit identity.
  Future<void> _markSynced(
    String id,
    String? serverUpdatedAt, {
    required String pushedUpdatedAt,
  }) async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    final serverCols = serverUpdatedAt != null
        ? 'server_updated_at = ${sqlString(serverUpdatedAt)}, '
            'updated_at = ${sqlString(serverUpdatedAt)},'
        : '';
    await _db.customStatement('''
      UPDATE sender_bank_mappings
      SET sync_status = 'synced',
          sync_attempt_count = 0, sync_next_retry_at = NULL,
          sync_failure_class = NULL, sync_permanent = 0,
          $serverCols
          synced_at = ${sqlString(now)}
      WHERE id = ${sqlString(id)}
        AND updated_at = ${sqlString(pushedUpdatedAt)};
    ''');
  }

  /// A mapping with unsynced local intent (pending / failed): a pull must never
  /// overwrite or tombstone it.
  static bool _isUnsettledLocal(String? syncStatus) =>
      syncStatus == 'pending' || syncStatus == 'failed';

  /// G10: typed, bounded failure handling for one mapping. A permanent class (or
  /// reaching [kOutboxMaxAttempts]) is terminal — `sync_permanent = 1`, never
  /// retried, kept observable; a retryable class backs off exponentially.
  Future<void> _markFailed(String id, OutboxFailureClass failureClass) async {
    // A-5: an auth rejection never consumes an attempt — the row keeps its
    // state and is retried once the session is valid again. D-4: but it must
    // back off, or every poll re-sends the same rejected request.
    if (failureClass == OutboxFailureClass.auth) {
      final retryAt = dateTimeToSql(
          DateTime.now().toUtc().add(const Duration(minutes: 2)));
      await _db.customStatement(
        'UPDATE sender_bank_mappings '
        'SET sync_next_retry_at = ${sqlString(retryAt)} '
        'WHERE id = ${sqlString(id)};',
      );
      return;
    }
    final row = await _db.customSelect(
      'SELECT sync_attempt_count FROM sender_bank_mappings '
      'WHERE id = ${sqlString(id)} LIMIT 1;',
    ).getSingleOrNull();
    if (row == null) return;
    final attempts = row.read<int>('sync_attempt_count') + 1;
    final permanent =
        failureClass.isPermanent || attempts >= kOutboxMaxAttempts;
    final nextRetry = permanent
        ? null
        : dateTimeToSql(DateTime.now()
            .toUtc()
            .add(Duration(seconds: 30 * (1 << (attempts - 1).clamp(0, 7)))));
    await _db.customStatement('''
      UPDATE sender_bank_mappings
      SET sync_status = 'failed',
          sync_attempt_count = $attempts,
          sync_next_retry_at = ${sqlNullableString(nextRetry)},
          sync_failure_class = ${sqlString(failureClass.reason)},
          sync_permanent = ${permanent ? 1 : 0}
      WHERE id = ${sqlString(id)};
    ''');
  }

  /// Normalises a server timestamp value to the local SQL (ISO8601) form.
  static String? _ts(Object? value) =>
      value == null ? null : dateTimeToSql(DateTime.parse(value.toString()));
}

enum _Outcome { imported, updated, tombstoned, skipped }

class _SenderInvocation implements SyncPhaseLifecycle {
  _SenderInvocation(this.authority, this.handle, this.database, this.inherited, this.received, this.currentUserId);
  final AccountFenceAuthority authority;
  final AccountFenceHandle handle;
  @override
  final AppDatabase database;
  final SyncPhaseBinding? inherited;
  final AdmissionAuthority? received;
  final String? Function() currentUserId;
  String get uid => authority.ownerUid(handle);
  @override
  bool get isCurrent => currentUserId() == uid && authority.isCurrentForDatabase(handle, database) &&
      (inherited == null || inherited!.isCurrent) &&
      (received == null || (received!.uid == uid && received!.isCurrent &&
        AppSession.instance.captureLocalWorkAuthority()?.epoch == received!.epoch));
  void requireCurrent() {
    if (!isCurrent) throw const SenderMappingDeliveryStopped(SenderMappingDeliveryStopReason.stale);
  }
  @override
  Future<T> runLocal<T>(Future<T> Function() action) {
    requireCurrent();
    return authority.runCurrentLocal(handle, database, () {
      requireCurrent();
      return action();
    });
  }
}
const _senderRemoteKey = #senderMappingMutation;
class _SenderRemoteContext {
  const _SenderRemoteContext(this.invocation, this.intent, this.payload);
  final _SenderInvocation invocation;
  final AccountFenceSenderMappingIntent intent;
  final List<Map<String, dynamic>> payload;
}
class _SenderMutationRefusal implements Exception {
  const _SenderMutationRefusal(this.context, this.raw);
  final _SenderRemoteContext context;
  final supabase.PostgrestException raw;
}
class _SenderReceiptFailure implements Exception { const _SenderReceiptFailure(); }

class _SenderRemoteOrdinary implements Exception {
  const _SenderRemoteOrdinary(this.error, this.stack);
  final Object error;
  final StackTrace stack;
}
