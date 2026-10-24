import '../../../core/sync/sync_health.dart';
import 'dart:convert';
import 'dart:async';

import '../../../core/session/account_fence_authority.dart';
import '../../../core/session/admission_authority.dart';
import '../../../core/session/app_session.dart';
import '../../../core/sync/account_fence_retry.dart';
import '../../../core/sync/outbox_failure.dart';
import '../../../data/repositories/drift_smart_inbox_repository.dart';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/backend/supabase_config.dart';
import '../../../core/utils/id_generator.dart';
import '../../../data/db/app_database.dart';
import '../../../data/db/sql_value_codec.dart';
import '../../../data/sync/seq_pull.dart';
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

  /// يدفع تغيير الحالة (رفض/معالجة) لصف الخادم المطابق للـ serverId ويعيد عدد
  /// الصفوف التي طابقها الخادم فعلًا (G11: صفر ≠ نجاح — لا ACK بلا صف).
  Future<int> pushStatus(String serverId, String status);
}

class SupabaseSmartInboxRemoteSource implements SmartInboxRemoteSource {
  const SupabaseSmartInboxRemoteSource();

  @override
  Future<int> pushStatus(String serverId, String status) async {
    final context = Zone.current[_inboxRemoteKey] as _InboxRemoteContext?;
    context?.invocation.requireCurrent();
    if (context != null && (context.intent.serverId != serverId ||
        context.intent.status != status)) {
      throw const SmartInboxDeliveryStopped(SmartInboxDeliveryStopReason.provenance);
    }
    // Construct synchronously outside the tagged await. Parsing is also outside.
    final response = Supabase.instance.client.from('user_smart_inbox')
        .update({'status': status}).eq('id', serverId).select('id');
    final List<Map<String, dynamic>> rows;
    try {
      rows = await response;
    } on PostgrestException catch (error) {
      if (context != null && decodeSmartInboxAccountDenial(error) != null) {
        throw _InboxMutationRefusal(context, error);
      }
      rethrow;
    }
    return rows.length;
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
/// G11: a server update that matched no row is a FAILURE, never an ACK.
class SmartInboxPushNoRowException implements Exception {
  const SmartInboxPushNoRowException(this.serverId);
  final String serverId;
  @override
  String toString() => 'SmartInboxPushNoRowException: no server row matched';
}

/// G11: local-only items (`local_capture:<payloadId>`, see
/// DriftSmartInboxRepository.saveUnprocessableCapture) have no server row; their
/// status is purely local and must never be sent to the server.
bool isLocalOnlySmartInboxId(String serverId) =>
    serverId.startsWith('local_capture:');

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
    /// C-3 — Smart Inbox items are user data. Defaults to DENY.
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
        _isPullEnabled = isPullEnabled,
        _remoteSource = remoteSource ?? const SupabaseSmartInboxRemoteSource(),
        _pageSize = pageSize,
        _getAuthUserId = getAuthUserId ?? _defaultGetAuthUserId,
        _mayEgress = mayEgress ?? _denyEgressByDefault;

  static Future<bool> _denyEgressByDefault() async => false;

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
  final Future<bool> Function() _mayEgress;
  final SyncHealth? _health;
  final AccountFenceRetry _fenceRetry;
  final SmartInboxRemoteSource _remoteSource;
  final Future<String?> Function() _getAuthUserId;
  final int _pageSize;
  final SeqPullGate? _seqGate;

  static const _cursorKey = 'smart_inbox';

  /// S3 gap#1: يدفع تغييرات الحالة المحلية (رفض/معالجة) إلى الخادم.
  /// specialized لصندوق الوارد (server-authored): لا outbox عام ولا محرك ثانٍ —
  /// يستنزف العلم pending_sync ويمسحه بعد النجاح. offline يبقيه للمحاولة التالية.
  bool _busy = false;
  Future<int> push() => pushWithPhase(SyncPhaseBinding());

  Future<int> pushWithPhase(SyncPhaseBinding phase) async {
    if (_busy) throw const SmartInboxDeliveryStopped(SmartInboxDeliveryStopReason.overlap);
    _busy = true;
    final inherited = phase.isBound ? phase : null;
    void supplied() {
      if (inherited != null && (!inherited.isCurrent || !identical(inherited.database, _db))) {
        throw const SmartInboxDeliveryStopped(SmartInboxDeliveryStopReason.stale);
      }
    }
    try {
      supplied();
      final authority = AccountFenceAuthority.shared;
      final handle = await authority.captureForDatabase(AppSession.instance, _db);
      supplied();
      if (handle == null) throw const SmartInboxDeliveryStopped(SmartInboxDeliveryStopReason.unbound);
      final invocation = _InboxInvocation(authority, handle, _db, inherited);
      if (!phase.isBound) phase.bind(invocation);
      invocation.requireCurrent();
      final uid = await _getAuthUserId();
      invocation.requireCurrent();
      if (uid != authority.ownerUid(handle)) {
        throw const SmartInboxDeliveryStopped(SmartInboxDeliveryStopReason.stale);
      }
      final allowed = await _mayEgress();
      invocation.requireCurrent();
      if (!allowed) { phase.noteConsentBlocked(_health); return 0; }
      if (!_isPullEnabled()) return 0;
      final now = dateTimeToSql(_fenceRetry.clock().toUtc());
      final pending = await invocation.runLocal(() => _db.transaction(() => _db.customSelect(
        'SELECT * FROM smart_inbox_items WHERE pending_sync=1 '
        'AND (push_next_retry_at IS NULL OR push_next_retry_at<=${sqlString(now)});',
      ).get()));
      invocation.requireCurrent();
      var pushed = 0;
      for (final row in pending) {
        invocation.requireCurrent();
        final edit = _InboxEdit(row.read<String>('id'), row.read<String>('server_id'),
            row.read<String>('status'), row.read<String>('updated_at'));
        DriftSmartInboxRepository.parseEditStamp(edit.stamp);
        if (!const {'open', 'dismissed', 'resolved'}.contains(edit.status)) {
          throw const SmartInboxDeliveryStopped(SmartInboxDeliveryStopReason.provenance);
        }
        if (isLocalOnlySmartInboxId(edit.serverId)) {
          await _finishEdit(invocation, edit);
          continue;
        }
        final intent = await authority.captureSmartInboxIntent(handle, _db,
            localId: edit.id, serverId: edit.serverId, status: edit.status, editStamp: edit.stamp);
        invocation.requireCurrent();
        if (intent == null) continue;
        final context = _InboxRemoteContext(invocation, intent);
        try {
          final matched = await _fenceRetry.runItem(
            isCurrent: () => _retryCurrent(invocation, edit, uid!),
            body: () => retryAccountFenceMutation(() async {
              invocation.requireCurrent();
              final result = await runZoned(() => _remoteSource.pushStatus(edit.serverId, edit.status),
                  zoneValues: {_inboxRemoteKey: context});
              invocation.requireCurrent();
              return result;
            }),
          );
          invocation.requireCurrent();
          if (matched < 1) throw SmartInboxPushNoRowException(edit.serverId);
          if (await _finishEdit(invocation, edit)) pushed++;
        } on _InboxMutationRefusal catch (refusal) {
          if (!identical(refusal.context, context)) {
            throw const SmartInboxDeliveryStopped(SmartInboxDeliveryStopReason.provenance);
          }
          final result = await authority.acceptSmartInboxDenial(handle, _db, intent,
              decodeSmartInboxAccountDenial(refusal.raw)!);
          throw SmartInboxDeliveryStopped(SmartInboxDeliveryStopReason.denial,
              accepted: result.accepted, complete: result.complete);
        } on AccountFenceDeliveryCancellation { rethrow; }
        on AccountFenceRetryStopped {
          throw const SmartInboxDeliveryStopped(SmartInboxDeliveryStopReason.stale);
        } catch (error) {
          if (decodeSmartInboxAccountDenial(error) != null) {
            throw const SmartInboxDeliveryStopped(SmartInboxDeliveryStopReason.nonMutationRefusal);
          }
          invocation.requireCurrent();
          final contention = error is PostgrestException && error.code == '55P03';
          final matched = await _finishEdit(invocation, edit, error: error, contention: contention);
          if (matched) phase.noteFailure(_health, error);
          if (kDebugMode) debugPrint('[SmartInboxSync] push item skipped: $error');
        }
      }
      invocation.requireCurrent();
      return pushed;
    } on StaleAdmissionException {
      throw const SmartInboxDeliveryStopped(SmartInboxDeliveryStopReason.stale);
    } finally { _busy = false; }
  }

  Future<bool> _retryCurrent(_InboxInvocation invocation, _InboxEdit edit, String uid) async {
    invocation.requireCurrent();
    final current = await _getAuthUserId();
    invocation.requireCurrent();
    if (current != uid || !_isPullEnabled()) return false;
    final allowed = await _mayEgress();
    invocation.requireCurrent();
    if (!allowed) return false;
    final held = await invocation.runLocal(() => _db.transaction(() async =>
        await _db.customSelect('SELECT 1 FROM smart_inbox_items WHERE ${edit.predicate};')
            .getSingleOrNull() != null));
    invocation.requireCurrent();
    return held;
  }

  Future<bool> _finishEdit(_InboxInvocation invocation, _InboxEdit edit,
      {Object? error, bool contention = false}) async {
    invocation.requireCurrent();
    final changed = await invocation.runLocal(() => _db.transaction(() async {
      final row = await _db.customSelect('SELECT push_attempt_count FROM smart_inbox_items '
          'WHERE ${edit.predicate};').getSingleOrNull();
      if (row == null) return false;
      if (error == null) {
        await _db.customStatement('UPDATE smart_inbox_items SET pending_sync=0, '
            'push_attempt_count=0,push_next_retry_at=NULL,synced_at='
            '${sqlString(dateTimeToSql(_fenceRetry.clock().toUtc()))} WHERE ${edit.predicate};');
      } else {
        final attempts = row.read<int>('push_attempt_count') + (contention ? 0 : 1);
        final delay = contention ? _fenceRetry.cooldown :
            Duration(seconds: 30 * (1 << (attempts - 1).clamp(0, 7)));
        final next = dateTimeToSql(_fenceRetry.clock().toUtc().add(delay));
        await _db.customStatement('UPDATE smart_inbox_items SET push_attempt_count=$attempts,'
            'push_next_retry_at=${sqlString(next)} WHERE ${edit.predicate};');
      }
      return true;
    }));
    invocation.requireCurrent();
    return changed;
  }

  Future<SmartInboxSyncResult> pull({
    SyncCursor? from,
    bool Function()? isAdmitted,
  }) async {
    if (!await _mayEgress()) {
      _health?.noteConsentBlocked(SyncDomain.smartInbox);
      return const SmartInboxSyncResult();
    }
    if (!_isPullEnabled()) return const SmartInboxSyncResult();

    final userId = await _getAuthUserId();
    if (userId == null) return const SmartInboxSyncResult();
    final admitted = isAdmitted ?? alwaysAdmitted;

    int imported = 0;
    int updated = 0;
    int tombstoned = 0;

    var reachedEof = false;
    try {
      // WP-4: protocol selection (a reconcile pull `from` stays legacy).
      final plan = from == null && _seqGate != null
          ? await _seqGate.plan(userId)
          : const SeqPlan(SeqMode.legacy);
      if (plan.mode == SeqMode.stopped) {
        return const SmartInboxSyncResult(status: SyncPullStatus.failed);
      }
      final useSeq = plan.mode == SeqMode.seq;
      var cursor = from ?? await readSyncCursor(_db, _cursorKey);
      var seqCursor = useSeq ? await readSeqCursor(_db, userId, _cursorKey) : 0;
      final skipPages = useSeq && plan.isIdle(seqCursor);
      if (skipPages) reachedEof = true;
      while (!skipPages) {
        if (!admitted()) break;
        final rows = useSeq
            ? await _seqGate!.fetch(
                table: 'user_smart_inbox',
                userId: userId,
                afterSeq: seqCursor,
                limit: _pageSize,
              )
            : await _remoteSource.fetchRows(
                after: cursor,
                limit: _pageSize,
              );
        if (!admitted()) break;
        if (rows.isEmpty) {
          reachedEof = true;
          break;
        }

        final nextSeq = useSeq ? nextSeqOf(rows, seqCursor) : 0;
        final nextCursor = useSeq ? cursor : SyncCursor.fromServerRow(rows.last);
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
          if (useSeq) {
            await writeSeqCursor(_db, userId, _cursorKey, nextSeq);
          } else {
            await writeSyncCursor(_db, _cursorKey, nextCursor);
          }
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
        if (useSeq) seqCursor = nextSeq;
        if (rows.length < _pageSize) {
          reachedEof = true;
          break;
        }
      }
      if (useSeq && reachedEof) {
        await _seqGate!.markCaughtUp(userId, _cursorKey, seqCursor, plan);
      }
    } on ReconcilePullCancelled {
      // Lifecycle/ownership cancellation, not a transport failure.
      if (kDebugMode) debugPrint('[SmartInboxSync] reconciliation cancelled');
    } on AccountFenceDeliveryCancellation { rethrow; } catch (e) {
      _health?.noteFailure(SyncDomain.smartInbox, e);
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
          'SELECT id, server_updated_at, dismissed_locally, updated_at '
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

      final stamp = DriftSmartInboxRepository.nextEditStamp(existing.read<String>('updated_at'));
      await _db.customStatement('''
        UPDATE smart_inbox_items
        SET title = ${sqlString(title)},
            body = ${sqlNullableString(row['body'] as String?)},
            status = ${sqlString(row['status'] as String? ?? 'open')},
            confidence = ${row['confidence'] != null ? (row['confidence'] as num).toDouble() : 'NULL'},
            metadata_json = ${sqlString(jsonEncode(row['metadata'] ?? {}))},
            server_updated_at = ${sqlNullableString(serverUpdatedAt)},
            synced_at = ${sqlString(now)},
            updated_at = ${sqlString(stamp)}
        WHERE server_id = ${sqlString(serverId)};
      ''');
      return _RowOutcome.updated;
    }

    // New row — insert.
    final id = IdGenerator.next();
    final stamp = DriftSmartInboxRepository.nextEditStamp(null);
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
        ${sqlString(stamp)}
      );
    ''');
    return _RowOutcome.imported;
  }

  Future<bool> _processTombstone(Map<String, dynamic> row) async {
    final serverId = row['id'] as String?;
    if (serverId == null) return false;

    final existing = await _db
        .customSelect(
          'SELECT id, status, updated_at FROM smart_inbox_items '
          'WHERE server_id = ${sqlString(serverId)} LIMIT 1;',
        )
        .getSingleOrNull();
    if (existing == null) return false;

    if (existing.readNullable<String>('status') == 'dismissed') return false;

    final stamp = DriftSmartInboxRepository.nextEditStamp(existing.read<String>('updated_at'));
    await _db.customStatement('''
      UPDATE smart_inbox_items
      SET status = 'dismissed',
          updated_at = ${sqlString(stamp)}
      WHERE server_id = ${sqlString(serverId)};
    ''');
    return true;
  }
}

enum _RowOutcome { imported, updated, skipped }

class _InboxEdit {
  const _InboxEdit(this.id, this.serverId, this.status, this.stamp);
  final String id, serverId, status, stamp;
  String get predicate => 'id=${sqlString(id)} AND server_id=${sqlString(serverId)} '
      'AND status=${sqlString(status)} AND pending_sync=1 AND updated_at=${sqlString(stamp)}';
}
class _InboxInvocation implements SyncPhaseLifecycle {
  _InboxInvocation(this.authority, this.handle, this.database, this.inherited);
  final AccountFenceAuthority authority;
  final AccountFenceHandle handle;
  @override
  final AppDatabase database;
  final SyncPhaseBinding? inherited;
  @override
  bool get isCurrent => authority.isCurrentForDatabase(handle, database) &&
      (inherited == null || inherited!.isCurrent);
  void requireCurrent() {
    if (!isCurrent) throw const SmartInboxDeliveryStopped(SmartInboxDeliveryStopReason.stale);
  }
  @override
  Future<T> runLocal<T>(Future<T> Function() action) {
    requireCurrent();
    return authority.runCurrentLocal(handle, database, action);
  }
}
const _inboxRemoteKey = #smartInboxMutation;
class _InboxRemoteContext {
  const _InboxRemoteContext(this.invocation, this.intent);
  final _InboxInvocation invocation;
  final AccountFenceSmartInboxIntent intent;
}
class _InboxMutationRefusal implements Exception {
  const _InboxMutationRefusal(this.context, this.raw);
  final _InboxRemoteContext context;
  final PostgrestException raw;
}
