import 'dart:io';

import 'package:drift/drift.dart' show QueryRow, Variable;
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/backend/supabase_config.dart';
import '../../../core/utils/id_generator.dart';
import '../../../core/utils/install_id.dart';
import '../../../data/db/app_database.dart';
import '../../../data/db/sql_value_codec.dart';
import 'native_capture_bridge.dart';

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
    SupabaseClient Function()? getClient,
    Future<String?> Function()? getAuthUserId,
    Future<String> Function()? getInstallId,
    /// C-3 — notification delivery/open events are telemetry about the user.
    /// Defaults to DENY so a caller that forgets it produces no egress.
    Future<bool> Function()? mayEgress,
  })  : _db = db,
        _mayEgress = mayEgress ?? _denyEgressByDefault,
        _getClient = getClient ?? (() => Supabase.instance.client),
        _getAuthUserId = getAuthUserId ?? _defaultGetAuthUserId,
        _getInstallId = getInstallId ?? InstallId.get;

  static Future<bool> _denyEgressByDefault() async => false;

  final AppDatabase _db;
  final Future<bool> Function() _mayEgress;
  final SupabaseClient Function() _getClient;
  final Future<String?> Function() _getAuthUserId;
  final Future<String> Function() _getInstallId;

  /// Events older than this many failed attempts are marked synced anyway
  /// (given up on) so one permanently-unsendable row can't block every
  /// event behind it forever — the local outbox still has the raw event for
  /// manual inspection, it's just no longer retried.
  static const _maxAttemptsPerEvent = 8;
  static const _batchSize = 50;

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
    if (!await _mayEgress()) return;
    try {
      await _importNativeEvents();
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[NotificationLogSync] native import failed: $error');
      }
    }
    if (!SupabaseConfig.isConfigured) return;
    final uid = await _getAuthUserId();
    if (uid == null) {
      return; // guest — nothing authenticated to attribute rows to yet.
    }
    try {
      await _syncBatch(uid);
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

  Future<void> _importNativeEvents() async {
    final events =
        await NativeCaptureBridge.consumePendingNotificationLogEvents();
    if (events.isEmpty) return;
    for (final event in events) {
      final now = dateTimeToSql(DateTime.now().toUtc());
      final occurredAt =
          event.occurredAt != null ? dateTimeToSql(event.occurredAt!) : now;
      try {
        await _db.customInsert(
          '''
            INSERT INTO notification_log_events(
              id, notification_log_id, event_type, channel, notification_type,
              related_entity_type, related_entity_id, payload_json,
              error_code, error_reason, occurred_at, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, '{}', ?, ?, ?, ?);
          ''',
          variables: [
            Variable.withString(IdGenerator.next()),
            Variable.withString(event.notificationLogId),
            Variable.withString(event.eventType),
            Variable.withString(event.channel),
            Variable.withString(event.notificationType),
            _nullableString(event.relatedEntityType),
            _nullableString(event.relatedEntityId),
            _nullableString(event.errorCode),
            _nullableString(event.errorReason),
            Variable.withString(occurredAt),
            Variable.withString(now),
          ],
        );
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
  Future<void> _syncBatch(String userId) async {
    final installId = await _getInstallId();
    final rows = await _db.customSelect(
      'SELECT * FROM notification_log_events '
      'WHERE synced_at IS NULL '
      'ORDER BY created_at ASC, id ASC LIMIT ?;',
      variables: [Variable.withInt(_batchSize)],
    ).get();

    for (final row in rows) {
      final id = row.read<String>('id');
      final attemptCount = row.read<int>('sync_attempt_count');
      if (attemptCount >= _maxAttemptsPerEvent) {
        await _markSynced(id);
        continue;
      }
      try {
        await _syncOne(row, userId: userId, installId: installId);
        await _markSynced(id);
      } catch (error) {
        await _bumpAttempt(id);
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

  Future<void> _markSynced(String id) async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    await _db.customUpdate(
      'UPDATE notification_log_events SET synced_at = ? WHERE id = ?;',
      variables: [Variable.withString(now), Variable.withString(id)],
    );
  }

  Future<void> _bumpAttempt(String id) async {
    await _db.customUpdate(
      'UPDATE notification_log_events '
      'SET sync_attempt_count = sync_attempt_count + 1 WHERE id = ?;',
      variables: [Variable.withString(id)],
    );
  }

  static Variable<String> _nullableString(String? value) =>
      value == null ? const Variable<String>(null) : Variable.withString(value);
}
