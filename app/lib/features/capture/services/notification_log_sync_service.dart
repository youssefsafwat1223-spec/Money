import 'dart:io';

import '../../../core/session/account_fence_authority.dart';
import '../../../core/session/admission_authority.dart';
import '../../../core/session/app_session.dart';
import '../../../core/sync/account_fence_retry.dart';
import '../../../core/sync/outbox_failure.dart';
import '../../../core/sync/sync_health.dart';
import 'dart:convert';

import 'package:drift/drift.dart' show QueryRow, Variable;
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/backend/supabase_config.dart';
import '../../../core/utils/install_id.dart';
import '../../../core/privacy/consent_authority.dart';
import '../../../data/db/app_database.dart';
import '../../../data/db/sql_value_codec.dart';
import 'native_capture_bridge.dart';
import 'notification_log_ownership.dart';

/// Opportunistically syncs the local `notification_log_events` outbox
/// (written by [NotificationLogService] and drained from the iOS Shortcut
/// extension's native queue) to Supabase's `notification_logs` table — see
/// docs/NOTIFICATION_PIPELINE_AUDIT.md Phase 1.
///
/// Uploads are opportunistic; lifetime cancellation is explicit so callers
/// cannot continue an old cycle on a successor account. Each native import SQL
/// Future is drained locally; external native consume/ACK stays outside it.
enum NotificationUploadOutcome { completed, deferred }

class NotificationLogSyncService {
  NotificationLogSyncService({
    required AppDatabase db,
    Future<NotificationLogOrigin?> Function()? readOrigin,
    Future<List<NativeNotificationLogEvent>> Function(String uid, int generation)?
        consumeNativeEvents,
    Future<bool> Function(NativeNotificationLogEvent event)? acknowledgeNativeEvent,
    SupabaseClient Function()? getClient,
    Future<String?> Function()? getAuthUserId,
    String? Function()? getCurrentAuthUserId,
    Future<String> Function()? getInstallId,
    /// C-3 — notification delivery/open events are telemetry about the user.
    /// Defaults to DENY so a caller that forgets it produces no egress.
    Future<bool> Function()? mayEgress,
  })  : _db = db,
        _readOrigin = readOrigin,
        _consumeNativeEvents = consumeNativeEvents,
        _acknowledgeNativeEvent = acknowledgeNativeEvent,
        _mayEgress = mayEgress ?? _denyEgressByDefault,
        _getClient = getClient ?? (() => Supabase.instance.client),
        _getAuthUserId = getAuthUserId ?? _defaultGetAuthUserId,
        _getCurrentAuthUserId = getCurrentAuthUserId ?? _defaultCurrentAuthUserId,
        _getInstallId = getInstallId ?? InstallId.get;

  static Future<bool> _denyEgressByDefault() async => false;

  bool _busy = false;
  final AccountFenceRetry _retry = AccountFenceRetry();
  final AppDatabase _db;
  final Future<bool> Function(NativeNotificationLogEvent event)? _acknowledgeNativeEvent;
  final Future<List<NativeNotificationLogEvent>> Function(String uid, int generation)?
      _consumeNativeEvents;
  final Future<NotificationLogOrigin?> Function()? _readOrigin;
  Future<NotificationLogOrigin?> _origin() =>
      _readOrigin?.call() ?? readNotificationLogOrigin(_db);
  final Future<bool> Function() _mayEgress;
  final SupabaseClient Function() _getClient;
  final Future<String?> Function() _getAuthUserId;
  final String? Function() _getCurrentAuthUserId;
  final Future<String> Function() _getInstallId;

  /// Exhausted events remain unsynced for inspection, without blocking later
  /// eligible rows or causing additional network retries.
  static const _maxAttemptsPerEvent = 8;
  static const _batchSize = 50;

  static String? _defaultCurrentAuthUserId() {
    try { return Supabase.instance.client.auth.currentUser?.id; }
    catch (_) { return null; }
  }

  static Future<String?> _defaultGetAuthUserId() async {
    if (!SupabaseConfig.isConfigured) return null;
    try {
      return Supabase.instance.client.auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  /// Runs one sync pass: drains any native (iOS Shortcut) events into the
  /// local outbox, then pushes unsynced local outbox rows to Supabase in
  /// creation order (oldest first) so a 'created' event for one
  /// notification_log_id is never upserted after a later 'sent'/'opened'
  /// event for the same id — see the ordering note on [_syncBatch].
  Future<void> sync() async { await syncWithPhase(SyncPhaseBinding()); }

  Future<NotificationUploadOutcome> syncWithPhase(SyncPhaseBinding phase) =>
      _run(phase, importNative: true);

  /// Internal upload component: omits configuration and native import only.
  @visibleForTesting
  Future<void> debugSyncBatch(String userId) async {
    await _run(SyncPhaseBinding(), importNative: false, expectedUid: userId);
  }

  Future<NotificationUploadOutcome> _run(SyncPhaseBinding phase,
      {required bool importNative, String? expectedUid}) async {
    if (_busy) throw const NotificationDeliveryStopped(NotificationDeliveryStopReason.overlap);
    _busy = true;
    final inherited = phase.isBound ? phase : null;
    void supplied() {
      if (inherited != null && (!inherited.isCurrent || !identical(inherited.database, _db))) {
        throw const NotificationDeliveryStopped(NotificationDeliveryStopReason.stale);
      }
    }
    try {
      supplied();
      final authority = AccountFenceAuthority.shared;
      final handle = await authority.captureForDatabase(AppSession.instance, _db);
      supplied();
      if (handle == null) throw const NotificationDeliveryStopped(NotificationDeliveryStopReason.unbound);
      final invocation = _NotificationInvocation(authority, handle, _db, inherited);
      if (!phase.isBound) phase.bind(invocation);
      invocation.requireCurrent();
      final origin = await _origin();
      invocation.requireCurrent();
      if (origin == null || origin.uid != invocation.uid ||
          (expectedUid != null && expectedUid != invocation.uid)) { return NotificationUploadOutcome.deferred; }
      if (!await _positive(invocation, origin)) return NotificationUploadOutcome.deferred;
      if (importNative) {
        try { await _importNativeEvents(original: invocation, capturedOrigin: origin); }
        on AccountFenceDeliveryCancellation { rethrow; }
        catch (error) {
          invocation.requireCurrent();
          if (kDebugMode) { debugPrint('[NotificationLogSync] native import failed: $error'); }
        }
        invocation.requireCurrent();
        if (!await _positive(invocation, origin)) return NotificationUploadOutcome.deferred;
        if (!SupabaseConfig.isConfigured) return NotificationUploadOutcome.deferred;
      }
      return await _syncBatch(invocation, origin);
    } on AccountFenceDeliveryCancellation { rethrow; }
    on StaleAdmissionException {
      throw const NotificationDeliveryStopped(NotificationDeliveryStopReason.stale);
    } on PostgrestException catch (error) {
      if (decodeNotificationAccountDenial(error) != null) {
        throw const NotificationDeliveryStopped(NotificationDeliveryStopReason.nonMutationRefusal);
      }
      rethrow;
    } finally { _busy = false; }
  }

  Future<bool> _positive(_NotificationInvocation invocation, NotificationLogOrigin origin) async {
    invocation.requireCurrent();
    final uid = await _getAuthUserId();
    invocation.requireCurrent();
    if (uid != invocation.uid || !origin.isCurrent()) return false;
    final holds = await origin.holds();
    invocation.requireCurrent();
    if (!holds || !origin.isCurrent()) return false;
    final allowed = await _mayEgress();
    invocation.requireCurrent();
    return allowed && !ConsentAuthority.egressFrozen && origin.isCurrent() && _sdkCurrent(invocation);
  }

  bool _sdkCurrent(_NotificationInvocation invocation) =>
      _getCurrentAuthUserId() == invocation.uid &&
      _getClient().auth.currentUser?.id == invocation.uid;

  @visibleForTesting
  Future<void> debugImportNativeEvents() => _importNativeEvents();

  Future<_NotificationInvocation> _captureNativeImportInvocation() async {
    final authority = AccountFenceAuthority.shared;
    final handle = await authority.captureForDatabase(AppSession.instance, _db);
    if (handle == null) {
      throw const NotificationDeliveryStopped(NotificationDeliveryStopReason.unbound);
    }
    final invocation = _NotificationInvocation(authority, handle, _db, null);
    invocation.requireCurrent();
    return invocation;
  }

  Future<bool> _nativeOriginHolds(_NotificationInvocation invocation,
      NotificationLogOrigin origin) async {
    invocation.requireCurrent();
    final holds = await origin.holds();
    invocation.requireCurrent();
    return holds;
  }

  Future<void> _importNativeEvents({_NotificationInvocation? original,
      NotificationLogOrigin? capturedOrigin}) async {
    final invocation = original ?? await _captureNativeImportInvocation();
    invocation.requireCurrent();
    final origin = capturedOrigin ?? await _origin();
    invocation.requireCurrent();
    if (origin == null || origin.uid != invocation.uid ||
        origin.nativeGeneration == null || !await _nativeOriginHolds(invocation, origin)) {
      return;
    }
    invocation.requireCurrent();
    if (!origin.isCurrent()) return;
    final events = await (_consumeNativeEvents?.call(origin.uid, origin.nativeGeneration!) ??
        NativeCaptureBridge.consumePendingNotificationLogEvents(
          ownerUid: origin.uid, ownerGeneration: origin.nativeGeneration));
    if (!await _nativeOriginHolds(invocation, origin)) return;
    if (events.isEmpty) return;
    for (final event in events) {
      if (!await _nativeOriginHolds(invocation, origin)) return;
      final eventId = event.eventId;
      if (eventId == null || !RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$').hasMatch(eventId)) continue;
      if (event.originKind != 'native' || event.ownerUid != origin.uid ||
          event.ownerGeneration != origin.nativeGeneration) {
        continue;
      }
      final now = dateTimeToSql(DateTime.now().toUtc());
      final occurredAt =
          event.occurredAt != null ? dateTimeToSql(event.occurredAt!) : now;
      try {
        final inserted = await invocation.runLocal(() async {
          invocation.requireCurrent();
          if (!origin.isCurrent()) return false;
          await _db.customInsert(
          '''
            INSERT OR IGNORE INTO notification_log_events(
              id, notification_log_id, event_type, channel, notification_type,
              related_entity_type, related_entity_id, payload_json,
              error_code, error_reason, occurred_at, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
          ''',
          variables: [
            Variable.withString('native:$eventId'),
            Variable.withString(event.notificationLogId),
            Variable.withString(event.eventType),
            Variable.withString(event.channel),
            Variable.withString(event.notificationType),
            _nullableString(event.relatedEntityType),
            _nullableString(event.relatedEntityId),
            Variable.withString(jsonEncode({
              NotificationLogOrigin.payloadKey: origin.payload('native'),
            })),
            _nullableString(event.errorCode),
            _nullableString(event.errorReason),
            Variable.withString(occurredAt),
            Variable.withString(now),
          ],
          );
          return true;
        });
        invocation.requireCurrent();
        if (!inserted || !await _nativeOriginHolds(invocation, origin)) return;
        final persisted = await invocation.runLocal(() {
          invocation.requireCurrent();
          if (!origin.isCurrent()) return Future<QueryRow?>.value(null);
          return _db.customSelect(
          'SELECT * FROM notification_log_events WHERE id = ?',
          variables: [Variable.withString('native:$eventId')],
          ).getSingleOrNull();
        });
        invocation.requireCurrent();
        if (!await _nativeOriginHolds(invocation, origin)) return;
        if (persisted == null ||
            persisted.read<String>('notification_log_id') != event.notificationLogId ||
            persisted.read<String>('event_type') != event.eventType ||
            persisted.read<String>('channel') != event.channel ||
            persisted.read<String>('notification_type') != event.notificationType ||
            persisted.readNullable<String>('related_entity_type') != event.relatedEntityType ||
            persisted.readNullable<String>('related_entity_id') != event.relatedEntityId ||
            persisted.readNullable<String>('error_code') != event.errorCode ||
            persisted.readNullable<String>('error_reason') != event.errorReason ||
            (event.occurredAt != null && persisted.read<String>('occurred_at') != occurredAt) ||
            !origin.owns(persisted.read<String>('payload_json'))) {
          continue;
        }
        invocation.requireCurrent();
        if (!origin.isCurrent()) return;
        await (_acknowledgeNativeEvent?.call(event) ??
            NativeCaptureBridge.acknowledgeNotificationLogEvent(eventId: eventId,
              ownerUid: origin.uid, ownerGeneration: origin.nativeGeneration!));
        if (!await _nativeOriginHolds(invocation, origin)) return;
      } on AccountFenceDeliveryCancellation { rethrow; }
      on StaleAdmissionException {
        throw const NotificationDeliveryStopped(NotificationDeliveryStopReason.stale);
      } catch (error) {
        invocation.requireCurrent();
        if (kDebugMode) {
          debugPrint(
              '[NotificationLogSync] failed to import native event: $error');
        }
      }
    }
  }

  /// Processes unsynced rows strictly oldest-first and stops the pass at the
  /// first upload failure (rather than skipping ahead) so a later event for
  /// the same notification_log_id can never sync before an earlier one —
  /// upserting 'sent' before 'created' exists would otherwise be harmless,
  /// but upserting 'created' (status=pending) AFTER a already-synced 'sent'
  /// would wrongly regress the row's status backward.
  Future<NotificationUploadOutcome> _syncBatch(_NotificationInvocation invocation,
      NotificationLogOrigin origin) async {
    final installId = await _getInstallId();
    invocation.requireCurrent();
    if (!await _positive(invocation, origin)) return NotificationUploadOutcome.deferred;
    final rows = await invocation.runLocal(() => _db.transaction(() => _db.customSelect(
      // The tie-breaker is `rowid`, NOT `id`. `id` is a random 16-byte value
      // (`IdGenerator.next()`), so when two events for the same notification
      // land in the same `created_at` tick — which is the NORMAL case, since
      // `recordCreated` is followed by `recordSent` microseconds later — the
      // upload order was decided at random. That is exactly the regression the
      // comment above warns about: 'created' (status=pending) upserted after
      // an already-synced 'sent' drags the row's status backward.
      //
      // `notification_log_events` is a rowid table, so `rowid` is monotonic
      // with insertion and breaks the tie in true insertion order. No schema
      // change, no migration.
      r'''SELECT * FROM notification_log_events
         WHERE synced_at IS NULL AND sync_attempt_count < ?
           AND json_extract(CASE WHEN json_valid(payload_json) THEN payload_json ELSE '{}' END,
                            '$._notification_origin.uid') = ?
           AND ((json_extract(CASE WHEN json_valid(payload_json) THEN payload_json ELSE '{}' END,
                              '$._notification_origin.kind') = 'local'
                 AND json_extract(CASE WHEN json_valid(payload_json) THEN payload_json ELSE '{}' END,
                                  '$._notification_origin.generation') = ?)
             OR (json_extract(CASE WHEN json_valid(payload_json) THEN payload_json ELSE '{}' END,
                              '$._notification_origin.kind') = 'native'
                 AND json_extract(CASE WHEN json_valid(payload_json) THEN payload_json ELSE '{}' END,
                                  '$._notification_origin.generation') = ?))
         ORDER BY created_at ASC, rowid ASC LIMIT ?;''',
      variables: [Variable.withInt(_maxAttemptsPerEvent), Variable.withString(origin.uid),
        Variable.withString(origin.localGeneration), Variable<int>(origin.nativeGeneration),
        Variable.withInt(_batchSize)],
    ).get()));
    invocation.requireCurrent();
    for (final row in rows) {
      final snapshot = Map<String, Object?>.unmodifiable(row.data);
      if (!origin.owns(row.read<String>('payload_json'))) continue;
      if (!await _positive(invocation, origin)) return NotificationUploadOutcome.deferred;
      final payload = _payload(row, userId: invocation.uid, installId: installId);
      if (payload == null) {
        await _finish(invocation, snapshot, acknowledged: true);
        continue;
      }
      final intent = await invocation.authority.captureNotificationIntent(invocation.handle, _db, snapshot);
      invocation.requireCurrent();
      if (intent == null) continue;
      try {
        await _retry.runItem(isCurrent: () async {
          if (!await _positive(invocation, origin)) return false;
          final matched = await invocation.runLocal(() => _db.transaction(() => _matches(snapshot)));
          invocation.requireCurrent();
          return matched && origin.isCurrent() && _sdkCurrent(invocation);
        }, body: () => retryAccountFenceMutation(() => _send(invocation, intent, payload)));
      } on _NotificationMutationRefusal catch (refusal) {
        if (!identical(refusal.invocation, invocation) || !identical(refusal.intent, intent)) {
          throw const NotificationDeliveryStopped(NotificationDeliveryStopReason.provenance);
        }
        // Negative lifetime is independent of temporary positive readiness.
        final result = await invocation.authority.acceptNotificationDenial(invocation.handle, _db,
            intent, decodeNotificationAccountDenial(refusal.raw)!);
        throw NotificationDeliveryStopped(NotificationDeliveryStopReason.denial,
            accepted: result.accepted, complete: result.complete);
      } on AccountFenceDeliveryCancellation { rethrow; }
      on AccountFenceRetryStopped { return NotificationUploadOutcome.deferred; }
      on _NotificationUnprovenFailure catch (failure) {
        if (decodeNotificationAccountDenial(failure.error) != null) {
          throw const NotificationDeliveryStopped(NotificationDeliveryStopReason.nonMutationRefusal);
        }
        Error.throwWithStackTrace(failure.error, failure.stack);
      } on PostgrestException catch (error) {
        if (decodeNotificationAccountDenial(error) != null) {
          throw const NotificationDeliveryStopped(NotificationDeliveryStopReason.nonMutationRefusal);
        }
        if (error is _NotificationMutationContention && identical(error.invocation, invocation) &&
            identical(error.intent, intent)) { return NotificationUploadOutcome.deferred; }
        rethrow; // A local/preflight exception is not a remote failure.
      } on _NotificationRemoteFailure catch (failure) {
        if (!await _positive(invocation, origin)) return NotificationUploadOutcome.deferred;
        await _finish(invocation, snapshot, acknowledged: false);
        if (kDebugMode) { debugPrint('[NotificationLogSync] upload failed: ${failure.error}'); }
        return NotificationUploadOutcome.completed;
      }
      // Local ACK failures cannot enter the remote-failure/attempt path.
      if (!await _positive(invocation, origin)) return NotificationUploadOutcome.deferred;
      await _finish(invocation, snapshot, acknowledged: true);
      invocation.requireCurrent();
    }
    return NotificationUploadOutcome.completed;
  }

  Future<void> _send(_NotificationInvocation invocation,
      AccountFenceNotificationIntent intent, Map<String, dynamic> payload) async {
    final PostgrestFilterBuilder<dynamic> response;
    try {
      invocation.requireCurrent();
      final client = _getClient();
      if (_getCurrentAuthUserId() != invocation.uid || client.auth.currentUser?.id != invocation.uid) {
        throw const NotificationDeliveryStopped(NotificationDeliveryStopReason.stale);
      }
      invocation.requireCurrent();
      if (ConsentAuthority.egressFrozen) {
        throw const NotificationDeliveryStopped(NotificationDeliveryStopReason.stale);
      }
      // Only awaiting the actual SDK Future below establishes remote origin.
      response = client.from('notification_logs').upsert(payload, onConflict: 'id');
    } on AccountFenceDeliveryCancellation { rethrow; }
    catch (error, stack) { throw _NotificationUnprovenFailure(error, stack); }
    try { await response; }
    on PostgrestException catch (error) {
      if (decodeNotificationAccountDenial(error) != null) {
        throw _NotificationMutationRefusal(invocation, intent, error);
      }
      if (error.code == '55P03') throw _NotificationMutationContention(invocation, intent, error);
      throw _NotificationRemoteFailure(error);
    } on AccountFenceDeliveryCancellation { rethrow; }
    catch (error) { throw _NotificationRemoteFailure(error); }
  }

  Future<bool> _matches(Map<String, Object?> snapshot) async {
    final row = await _db.customSelect('SELECT * FROM notification_log_events WHERE id = ?',
        variables: [Variable.withString(snapshot['id'] as String)]).getSingleOrNull();
    return row != null && mapEquals(row.data, snapshot);
  }

  Future<void> _finish(_NotificationInvocation invocation, Map<String, Object?> snapshot,
      {required bool acknowledged}) => invocation.runLocal(() => _db.transaction(() async {
    if (!await _matches(snapshot)) return;
    await _db.customUpdate(acknowledged
        ? 'UPDATE notification_log_events SET synced_at = ? WHERE id = ?;'
        : 'UPDATE notification_log_events SET sync_attempt_count = sync_attempt_count + 1 WHERE id = ?;',
        variables: [if (acknowledged) Variable.withString(dateTimeToSql(DateTime.now().toUtc())),
          Variable.withString(snapshot['id'] as String)]);
  }));

  Map<String, dynamic>? _payload(
    QueryRow row, {
    required String userId,
    required String installId,
  }) {
    final logId = row.read<String>('notification_log_id');
    final eventType = row.read<String>('event_type');
    final channel = row.read<String>('channel');
    final notificationType = row.read<String>('notification_type');
    final relatedEntityType = row.readNullable<String>('related_entity_type');
    final relatedEntityId = row.readNullable<String>('related_entity_id');
    final errorCode = row.readNullable<String>('error_code');
    final errorReason = row.readNullable<String>('error_reason');
    final occurredAt = row.read<String>('occurred_at');
    final platform =
        Platform.isIOS ? 'ios' : (Platform.isAndroid ? 'android' : null);

    final base = <String, dynamic>{
      'id': logId,
      'user_id': userId,
      'install_id': installId,
      'notification_type': notificationType,
      'channel': channel,
      if (relatedEntityType != null) 'related_entity_type': relatedEntityType,
      if (relatedEntityId != null) 'related_entity_id': relatedEntityId,
      if (platform != null) 'device_platform': platform,
    };

    return switch (eventType) {
      'created' => {...base, 'status': 'pending', 'created_at': occurredAt},
      'queued' => {...base, 'status': 'queued', 'queued_at': occurredAt},
      'sent' => {...base, 'status': 'sent', 'sent_at': occurredAt},
      'failed' => {...base, 'status': 'failed', 'failed_at': occurredAt,
        if (errorCode != null) 'error_code': errorCode,
        if (errorReason != null) 'error_reason': errorReason},
      'opened' => ({...base, 'status': 'opened', 'opened_at': occurredAt}..remove('channel')),
      _ => null, // Existing defensive no-request ACK compatibility.
    };
  }

  static Variable<String> _nullableString(String? value) =>
      value == null ? const Variable<String>(null) : Variable.withString(value);
}

class _NotificationInvocation implements SyncPhaseLifecycle {
  _NotificationInvocation(this.authority, this.handle, this.database, this.inherited);
  final AccountFenceAuthority authority;
  final AccountFenceHandle handle;
  @override
  final AppDatabase database;
  final SyncPhaseBinding? inherited;
  String get uid => authority.ownerUid(handle);
  @override
  bool get isCurrent => authority.isCurrentForDatabase(handle, database) &&
      (inherited == null || (inherited!.isCurrent && identical(inherited!.database, database)));
  void requireCurrent() {
    if (!isCurrent) throw const NotificationDeliveryStopped(NotificationDeliveryStopReason.stale);
  }
  @override
  Future<T> runLocal<T>(Future<T> Function() action) {
    requireCurrent();
    return authority.runCurrentLocal(handle, database, () { requireCurrent(); return action(); });
  }
}
class _NotificationMutationRefusal implements Exception {
  const _NotificationMutationRefusal(this.invocation, this.intent, this.raw);
  final _NotificationInvocation invocation;
  final AccountFenceNotificationIntent intent;
  final PostgrestException raw;
}
class _NotificationRemoteFailure implements Exception {
  const _NotificationRemoteFailure(this.error);
  final Object error;
}

class _NotificationUnprovenFailure implements Exception {
  const _NotificationUnprovenFailure(this.error, this.stack);
  final Object error;
  final StackTrace stack;
}
class _NotificationMutationContention extends PostgrestException {
  _NotificationMutationContention(this.invocation, this.intent, PostgrestException raw)
      : super(message: raw.message, code: raw.code, details: raw.details, hint: raw.hint);
  final _NotificationInvocation invocation;
  final AccountFenceNotificationIntent intent;
}
