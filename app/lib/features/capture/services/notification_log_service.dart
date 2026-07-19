import 'package:drift/drift.dart' show Variable;
import 'package:flutter/foundation.dart';

import '../../../core/utils/id_generator.dart';
import '../../../data/db/app_database.dart';
import '../../../data/db/sql_value_codec.dart';

/// Notification channels tracked by the Phase 1 pipeline
/// (docs/NOTIFICATION_PIPELINE_AUDIT.md). Mirrors the CHECK constraint on
/// `notification_logs.channel` in supabase/migrations/0052_notification_logs.sql.
class NotificationLogChannel {
  NotificationLogChannel._();

  static const localIos = 'local_ios';
  static const localAndroid = 'local_android';
  static const iosShortcutLocal = 'ios_shortcut_local';
  static const apns = 'apns';
}

/// Records notification lifecycle events (created/sent/failed/opened) into a
/// durable local outbox (`notification_log_events`), synced opportunistically
/// to Supabase's `notification_logs` by [NotificationLogSyncService].
///
/// Writes here must never block showing/scheduling a notification and must
/// never throw into the caller — a logging failure is always swallowed after
/// a debug-mode print, matching every other secondary/best-effort write in
/// this codebase (see `_recordHistory` in local_notification_service.dart).
///
/// Never pass raw SMS text, full message bodies, or device tokens into
/// [payload] or [errorReason] — this table is diagnostics/routing-only.
class NotificationLogService {
  NotificationLogService(this._db);

  final AppDatabase _db;

  /// Starts a new notification attempt and returns its stable
  /// `notification_log_id`. The SAME id must be threaded through every later
  /// call (recordQueued/recordSent/recordFailed/recordOpened) for this one
  /// attempt — never regenerate it mid-flight.
  Future<String> recordCreated({
    required String channel,
    required String notificationType,
    String? relatedEntityType,
    String? relatedEntityId,
    Map<String, dynamic> payload = const {},
  }) async {
    final logId = IdGenerator.uuidV4();
    await _insertEvent(
      logId: logId,
      eventType: 'created',
      channel: channel,
      notificationType: notificationType,
      relatedEntityType: relatedEntityType,
      relatedEntityId: relatedEntityId,
      payload: payload,
    );
    return logId;
  }

  Future<void> recordQueued({
    required String logId,
    required String channel,
    required String notificationType,
    String? relatedEntityType,
    String? relatedEntityId,
  }) =>
      _insertEvent(
        logId: logId,
        eventType: 'queued',
        channel: channel,
        notificationType: notificationType,
        relatedEntityType: relatedEntityType,
        relatedEntityId: relatedEntityId,
      );

  Future<void> recordSent({
    required String logId,
    required String channel,
    required String notificationType,
    String? relatedEntityType,
    String? relatedEntityId,
  }) =>
      _insertEvent(
        logId: logId,
        eventType: 'sent',
        channel: channel,
        notificationType: notificationType,
        relatedEntityType: relatedEntityType,
        relatedEntityId: relatedEntityId,
      );

  Future<void> recordFailed({
    required String logId,
    required String channel,
    required String notificationType,
    required Object error,
    StackTrace? stackTrace,
    String? relatedEntityType,
    String? relatedEntityId,
  }) =>
      _insertEvent(
        logId: logId,
        eventType: 'failed',
        channel: channel,
        notificationType: notificationType,
        relatedEntityType: relatedEntityType,
        relatedEntityId: relatedEntityId,
        errorCode: error.runtimeType.toString(),
        errorReason: _sanitizeError(error, stackTrace),
      );

  /// Idempotent — a repeated tap on the same notification is a no-op if an
  /// 'opened' event for [logId] already exists locally.
  Future<void> recordOpened({
    required String logId,
    required String channel,
    required String notificationType,
    String? relatedEntityType,
    String? relatedEntityId,
  }) async {
    try {
      final existing = await _db.customSelect(
        "SELECT 1 FROM notification_log_events "
        "WHERE notification_log_id = ? AND event_type = 'opened' LIMIT 1;",
        variables: [Variable.withString(logId)],
      ).getSingleOrNull();
      if (existing != null) return;
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[NotificationLog] opened-dedup check failed: $error');
      }
    }
    await _insertEvent(
      logId: logId,
      eventType: 'opened',
      channel: channel,
      notificationType: notificationType,
      relatedEntityType: relatedEntityType,
      relatedEntityId: relatedEntityId,
    );
  }

  Future<void> _insertEvent({
    required String logId,
    required String eventType,
    required String channel,
    required String notificationType,
    String? relatedEntityType,
    String? relatedEntityId,
    Map<String, dynamic> payload = const {},
    String? errorCode,
    String? errorReason,
  }) async {
    try {
      final now = dateTimeToSql(DateTime.now().toUtc());
      await _db.customInsert(
        '''
          INSERT INTO notification_log_events(
            id, notification_log_id, event_type, channel, notification_type,
            related_entity_type, related_entity_id, payload_json,
            error_code, error_reason, occurred_at, created_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        ''',
        variables: [
          Variable.withString(IdGenerator.next()),
          Variable.withString(logId),
          Variable.withString(eventType),
          Variable.withString(channel),
          Variable.withString(notificationType),
          _nullableString(relatedEntityType),
          _nullableString(relatedEntityId),
          Variable.withString(_encodeJson(payload)),
          _nullableString(errorCode),
          _nullableString(errorReason),
          Variable.withString(now),
          Variable.withString(now),
        ],
      );
      if (kDebugMode) {
        debugPrint(
          '[NotificationLog] $eventType logId=$logId channel=$channel '
          'type=$notificationType'
          '${errorCode != null ? ' errorCode=$errorCode' : ''}',
        );
      }
    } catch (error) {
      // Logging is always secondary to actually showing/scheduling the
      // notification — never let a local-DB write failure here propagate.
      if (kDebugMode) {
        debugPrint('[NotificationLog] failed to record $eventType: $error');
      }
    }
  }

  static Variable<String> _nullableString(String? value) =>
      value == null ? const Variable<String>(null) : Variable.withString(value);

  static String _sanitizeError(Object error, StackTrace? stackTrace) {
    final message = error.toString();
    final truncated =
        message.length > 300 ? '${message.substring(0, 300)}…' : message;
    if (stackTrace == null) return truncated;
    final trace = stackTrace.toString();
    final firstFrames = trace.split('\n').take(3).join(' | ');
    return '$truncated [${firstFrames.length > 300 ? firstFrames.substring(0, 300) : firstFrames}]';
  }

  static String _encodeJson(Map<String, dynamic> value) {
    if (value.isEmpty) return '{}';
    final buffer = StringBuffer('{');
    var first = true;
    for (final entry in value.entries) {
      if (!first) buffer.write(',');
      first = false;
      buffer
        ..write('"')
        ..write(entry.key.replaceAll('"', r'\"'))
        ..write('":"')
        ..write(entry.value.toString().replaceAll('"', r'\"'))
        ..write('"');
    }
    buffer.write('}');
    return buffer.toString();
  }
}
