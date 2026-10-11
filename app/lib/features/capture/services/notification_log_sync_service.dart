import 'dart:io';
import 'dart:convert';

import 'package:drift/drift.dart' show QueryRow, Variable;
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/backend/supabase_config.dart';
import '../../../core/privacy/cloud_egress_gate.dart';
import '../../../core/privacy/consent_authority.dart';
import '../../../core/utils/install_id.dart';
import '../../../data/db/app_database.dart';
import '../../../data/db/sql_value_codec.dart';
import 'native_capture_bridge.dart';
import 'notification_log_ownership.dart';

/// Opportunistically syncs the local `notification_log_events` outbox
/// (written by [NotificationLogService] and drained from the iOS Shortcut
/// extension's native queue) to Supabase's `notification_logs` table — see
/// docs/NOTIFICATION_PIPELINE_AUDIT.md Phase 1.
///
/// Never blocks notification display/scheduling and never throws into a
/// caller: every step is best-effort, matching every other opportunistic
/// sync path in this codebase (financial cache repair, ledger sync, etc.).
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
  Future<void> sync() async {
    // C-3 — these are delivery/open events about the user's notifications:
    // telemetry, not something the app needs to function. Read fresh at egress.
    final origin = await _origin();
    if (origin == null || !await origin.holds()) return;
    if (!await _mayEgress() || !origin.isCurrent()) return;
    try {
      await _importNativeEvents(origin);
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[NotificationLogSync] native import failed: $error');
      }
    }
    if (!SupabaseConfig.isConfigured) return;
    final uid = await _getAuthUserId();
    if (uid == null || uid != origin.uid || !await origin.holds()) {
      return; // guest — nothing authenticated to attribute rows to yet.
    }
    try {
      await _syncBatch(uid, origin);
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[NotificationLogSync] sync pass failed: $error');
      }
    }
  }

  /// Test seam — bypasses the [SupabaseConfig.isConfigured] compile-time
  /// gate that otherwise makes [sync] unreachable in a plain `flutter test`
  /// run (no dart-define). Exercises exactly the same upload logic as
  /// [sync]'s call to [_syncBatch].
  @visibleForTesting
  Future<void> debugSyncBatch(String userId) => _syncBatch(userId);

  @visibleForTesting
  Future<void> debugImportNativeEvents() => _importNativeEvents();

  Future<void> _importNativeEvents([NotificationLogOrigin? captured]) async {
    final origin = captured ?? await _origin();
    if (origin == null || origin.nativeGeneration == null || !await origin.holds()) return;
    final events = await (_consumeNativeEvents?.call(origin.uid, origin.nativeGeneration!) ??
        NativeCaptureBridge.consumePendingNotificationLogEvents(
          ownerUid: origin.uid, ownerGeneration: origin.nativeGeneration));
    if (!await origin.holds()) return;
    if (events.isEmpty) return;
    for (final event in events) {
      if (!await origin.holds()) return;
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
        if (!await origin.holds()) return;
        final persisted = await _db.customSelect(
          'SELECT * FROM notification_log_events WHERE id = ?',
          variables: [Variable.withString('native:$eventId')],
        ).getSingleOrNull();
        if (!await origin.holds()) return;
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
        await (_acknowledgeNativeEvent?.call(event) ??
            NativeCaptureBridge.acknowledgeNotificationLogEvent(eventId: eventId,
              ownerUid: origin.uid, ownerGeneration: origin.nativeGeneration!));
      } catch (error) {
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
  Future<void> _syncBatch(String userId, [NotificationLogOrigin? captured]) async {
    final gate = CloudEgressGate.instance;
    final epoch = gate.epoch;
    bool liveEgress() => gate.epoch == epoch && !ConsentAuthority.egressFrozen;
    final origin = captured ?? await _origin();
    if (origin == null || origin.uid != userId || !await origin.holds()) return;
    bool currentAtEffect() => origin.isCurrent() && liveEgress() &&
        _getCurrentAuthUserId() == userId;
    Future<bool> currentEgress() async {
      final uid = await _getAuthUserId();
      if (uid != userId || !await origin.holds()) return false;
      return currentAtEffect();
    }
    final installId = await _getInstallId();
    if (!await origin.holds()) return;
    final rows = await _db.customSelect(
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
    ).get();

    for (final row in rows) {
      if (!await origin.holds()) return;
      if (!origin.owns(row.read<String>('payload_json'))) continue;
      if (!await _mayEgress() || !await currentEgress() || !currentAtEffect()) {
        return;
      }
      final id = row.read<String>('id');
      try {
        await _syncOne(row, userId: userId, installId: installId);
        if (!await currentEgress() || !currentAtEffect()) return;
        await _markSynced(id, row.read<String>('payload_json'));
      } catch (error) {
        if (!await currentEgress() || !currentAtEffect()) return;
        await _bumpAttempt(id, row.read<String>('payload_json'));
        if (kDebugMode) {
          debugPrint('[NotificationLogSync] upload failed for $id: $error');
        }
        break;
      }
    }
  }

  Future<void> _syncOne(
    QueryRow row, {
    required String userId,
    required String installId,
  }) async {
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

    final client = _getClient();
    switch (eventType) {
      case 'created':
        await client.from('notification_logs').upsert({
          ...base,
          'status': 'pending',
          'created_at': occurredAt,
        }, onConflict: 'id');
      case 'queued':
        await client.from('notification_logs').upsert({
          ...base,
          'status': 'queued',
          'queued_at': occurredAt,
        }, onConflict: 'id');
      case 'sent':
        await client.from('notification_logs').upsert({
          ...base,
          'status': 'sent',
          'sent_at': occurredAt,
        }, onConflict: 'id');
      case 'failed':
        await client.from('notification_logs').upsert({
          ...base,
          'status': 'failed',
          'failed_at': occurredAt,
          if (errorCode != null) 'error_code': errorCode,
          if (errorReason != null) 'error_reason': errorReason,
        }, onConflict: 'id');
      case 'opened':
        // Deliberately omits 'channel': a tap can't always distinguish
        // apns from ios_shortcut_local (see the migration's column
        // comment), so this must never overwrite an already-correct value
        // recorded by the 'created'/'sent' event with a guess. If this
        // really is the first upsert for this id (channel not set by an
        // earlier event yet, e.g. that event is still stuck retrying),
        // channel is nullable specifically to allow that.
        final opened = {...base, 'status': 'opened', 'opened_at': occurredAt}
          ..remove('channel');
        await client.from('notification_logs').upsert(opened, onConflict: 'id');
      default:
        // Unknown event type — nothing to sync, but don't retry it forever.
        return;
    }
  }

  Future<void> _markSynced(String id, String payload) async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    await _db.customUpdate(
      'UPDATE notification_log_events SET synced_at = ? WHERE id = ? AND payload_json = ?;',
      variables: [Variable.withString(now), Variable.withString(id), Variable.withString(payload)],
    );
  }

  Future<void> _bumpAttempt(String id, String payload) async {
    await _db.customUpdate(
      'UPDATE notification_log_events '
      'SET sync_attempt_count = sync_attempt_count + 1 WHERE id = ? AND payload_json = ?;',
      variables: [Variable.withString(id), Variable.withString(payload)],
    );
  }

  static Variable<String> _nullableString(String? value) =>
      value == null ? const Variable<String>(null) : Variable.withString(value);
}
