import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../../domain/entities/captured_message.dart';

/// A single bank message drained from the native share queue.
class SharedCapturedMessage {
  const SharedCapturedMessage({
    required this.text,
    required this.source,
    this.id,
    this.receivedAt,
    this.sender,
    this.senderName,
    this.senderId,
    this.locale,
    this.status,
    this.failureReason,
  });

  final String? id;
  final String text;
  final String? sender;
  final String? senderName;
  final String? senderId;
  final String? locale;
  final String? status;
  final String? failureReason;
  final CapturedMessageSource source;
  final DateTime? receivedAt;
}

class ApnsTokenInfo {
  const ApnsTokenInfo({
    required this.token,
    required this.environment,
  });

  final String token;
  final String environment;
}

class ApnsRegistrationFailure {
  const ApnsRegistrationFailure({
    required this.message,
    required this.occurredAt,
    this.domain,
    this.code,
  });

  final String message;
  final DateTime occurredAt;
  final String? domain;
  final int? code;
}

class CaptureNotificationRoute {
  const CaptureNotificationRoute({
    this.payloadId,
    this.transactionId,
    this.smartInboxItemId,
    this.notificationType,
    this.source,
    this.receivedAt,
    this.notificationLogId,
  });

  final String? payloadId;
  final String? transactionId;
  final String? smartInboxItemId;
  final String? notificationType;
  final String? source;
  final DateTime? receivedAt;
  final String? notificationLogId;
}

/// One notification lifecycle event recorded natively (iOS Shortcut local
/// fallback notifications) and drained here for Flutter to fold into the
/// local `notification_log_events` outbox — see
/// docs/NOTIFICATION_PIPELINE_AUDIT.md Phase 1.
class NativeNotificationLogEvent {
  const NativeNotificationLogEvent({
    required this.notificationLogId,
    required this.eventType,
    required this.channel,
    required this.notificationType,
    this.relatedEntityType,
    this.relatedEntityId,
    this.errorCode,
    this.errorReason,
    this.occurredAt,
  });

  final String notificationLogId;
  final String eventType;
  final String channel;
  final String notificationType;
  final String? relatedEntityType;
  final String? relatedEntityId;
  final String? errorCode;
  final String? errorReason;
  final DateTime? occurredAt;
}

class NativeCaptureBridge {
  NativeCaptureBridge._();

  static const MethodChannel _channel =
      MethodChannel('money_companion/native_capture');
  static Future<void> Function()? _pendingMessagesHandler;
  static Future<void> Function(ApnsTokenInfo token)? _apnsTokenHandler;
  static Future<void> Function(ApnsRegistrationFailure failure)?
      _apnsFailureHandler;
  static Future<void> Function()? _notificationRouteHandler;

  static void setPendingMessagesHandler(
    Future<void> Function()? handler,
  ) {
    _pendingMessagesHandler = handler;
    _configureMethodHandler();
  }

  static void setApnsTokenUpdatedHandler(
    Future<void> Function(ApnsTokenInfo token)? handler,
  ) {
    _apnsTokenHandler = handler;
    _configureMethodHandler();
  }

  static void setApnsRegistrationFailedHandler(
    Future<void> Function(ApnsRegistrationFailure failure)? handler,
  ) {
    _apnsFailureHandler = handler;
    _configureMethodHandler();
  }

  static void setNotificationRouteHandler(
    Future<void> Function()? handler,
  ) {
    _notificationRouteHandler = handler;
    _configureMethodHandler();
  }

  static void _configureMethodHandler() {
    if (_pendingMessagesHandler == null &&
        _apnsTokenHandler == null &&
        _apnsFailureHandler == null &&
        _notificationRouteHandler == null) {
      _channel.setMethodCallHandler(null);
      return;
    }
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'pendingSharedMessagesAvailable') {
        await _pendingMessagesHandler?.call();
        return null;
      }
      if (call.method == 'apnsTokenUpdated') {
        final token = _tokenInfoFrom(call.arguments);
        if (token != null) {
          await _apnsTokenHandler?.call(token);
        }
        return null;
      }
      if (call.method == 'apnsRegistrationFailed') {
        final failure = _apnsFailureFrom(call.arguments);
        if (failure != null) {
          await _apnsFailureHandler?.call(failure);
        }
        return null;
      }
      if (call.method == 'pendingNotificationRouteAvailable') {
        await _notificationRouteHandler?.call();
        return null;
      }
      throw MissingPluginException('Unknown native capture callback');
    });
  }

  static Future<bool> hasSmsPermission() async {
    if (!Platform.isAndroid) {
      return false;
    }
    return await _channel.invokeMethod<bool>('hasSmsPermission') ?? false;
  }

  static Future<void> openAppSettings() async {
    if (!Platform.isAndroid) {
      return;
    }
    await _channel.invokeMethod<void>('openAppSettings');
  }

  static Future<bool> hasPendingSharedMessages() async {
    if (!Platform.isIOS) {
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>('hasPendingSharedMessages') ??
          false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<void> setBackendConfig({
    required bool cloudProcessingEnabled,
    required String installId,
    required String backendUrl,
    required String anonKey,
    bool aiConsentGranted = false,
    String? deviceSecret,
  }) async {
    if (!Platform.isIOS) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('setCaptureBackendConfig', {
        'cloudProcessingEnabled': cloudProcessingEnabled,
        'installId': installId,
        'deviceSecret': deviceSecret,
        'backendUrl': backendUrl,
        'anonKey': anonKey,
        'aiConsentGranted': aiConsentGranted,
      });
    } on MissingPluginException {
      return;
    }
  }

  static Future<ApnsTokenInfo?> registerForRemoteNotifications() async {
    if (!Platform.isIOS) return null;
    try {
      final result = await _channel
          .invokeMethod<Object?>('registerForRemoteNotifications');
      return _tokenInfoFrom(result);
    } on MissingPluginException {
      return null;
    }
  }

  static Future<ApnsTokenInfo?> getApnsToken() async {
    if (!Platform.isIOS) return null;
    try {
      final result = await _channel.invokeMethod<Object?>('getApnsToken');
      return _tokenInfoFrom(result);
    } on MissingPluginException {
      return null;
    }
  }

  static Future<ApnsRegistrationFailure?> getApnsRegistrationFailure() async {
    if (!Platform.isIOS) return null;
    try {
      final result =
          await _channel.invokeMethod<Object?>('getApnsRegistrationFailure');
      return _apnsFailureFrom(result);
    } on MissingPluginException {
      return null;
    }
  }

  static Future<String?> consumePendingSharedInput() async {
    if (!Platform.isIOS) {
      return null;
    }
    final text =
        await _channel.invokeMethod<String>('consumePendingSharedInput');
    if (text == null || text.trim().isEmpty) {
      return null;
    }
    return text;
  }

  /// Drains the full FIFO queue of bank messages captured by native sharing
  /// surfaces: iOS Share Extension/App Intent and Android ACTION_SEND.
  ///
  /// DESTRUCTIVE — prefer [peekPendingSharedMessages] +
  /// [acknowledgeSharedMessage] (per-item lease, MALI-012); this remains for
  /// compatibility with older native layers that lack the peek handler.
  static Future<List<SharedCapturedMessage>>
      consumePendingSharedMessages() async {
    return _fetchSharedMessages('consumePendingSharedMessages');
  }

  /// Returns the native capture queue WITHOUT deleting it (per-item lease,
  /// MALI-012). Call [acknowledgeSharedMessage] for each message only after
  /// its local import committed — a kill mid-drain re-delivers exactly the
  /// unacknowledged remainder instead of losing the whole batch.
  static Future<List<SharedCapturedMessage>> peekPendingSharedMessages() async {
    return _fetchSharedMessages('peekPendingSharedMessages');
  }

  /// Positively acknowledges (removes) one leased message from the native
  /// queue after its import committed. Returns false when the native layer
  /// doesn't support acks or the id was already gone.
  static Future<bool> acknowledgeSharedMessage(String payloadId) async {
    if (!Platform.isIOS && !Platform.isAndroid) return false;
    try {
      final removed = await _channel.invokeMethod<bool>(
        'acknowledgeSharedMessage',
        {'payloadId': payloadId},
      );
      return removed ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  static Future<List<SharedCapturedMessage>> _fetchSharedMessages(
    String method,
  ) async {
    if (!Platform.isIOS && !Platform.isAndroid) {
      return const [];
    }
    final String? json;
    try {
      json = await _channel.invokeMethod<String>(method);
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      // An older native layer without the peek/ack handlers reports
      // notImplemented as a PlatformException — treat as empty; the caller
      // falls back to the destructive consume path.
      return const [];
    }
    if (json == null || json.trim().isEmpty) {
      return const [];
    }
    final List<dynamic> decoded;
    try {
      decoded = jsonDecode(json) as List<dynamic>;
    } on FormatException {
      return const [];
    }
    final messages = <SharedCapturedMessage>[];
    for (final item in decoded) {
      if (item is! Map) {
        continue;
      }
      final text = (item['text'] as String?)?.trim() ?? '';
      if (text.isEmpty) {
        continue;
      }
      final rawId = (item['id'] as String?)?.trim();
      final rawSender = (item['sender'] as String?)?.trim();
      final rawSenderName = (item['senderName'] as String?)?.trim();
      final rawSenderId = (item['senderId'] as String?)?.trim();
      final rawSource = (item['source'] as String?)?.trim();
      final rawReceivedAt = (item['receivedAt'] as String?)?.trim();
      final rawLocale = (item['locale'] as String?)?.trim();
      final rawStatus = (item['status'] as String?)?.trim();
      final rawFailureReason = (item['failureReason'] as String?)?.trim();
      final sender = _firstNonEmpty([rawSenderId, rawSender, rawSenderName]);
      messages.add(
        SharedCapturedMessage(
          id: _emptyToNull(rawId),
          text: text,
          source: Platform.isIOS
              ? _iosCapturedSource(rawSource)
              : CapturedMessageSource.androidShare,
          sender: sender,
          senderName: _emptyToNull(rawSenderName),
          senderId: _emptyToNull(rawSenderId),
          locale: _emptyToNull(rawLocale),
          status: _emptyToNull(rawStatus),
          failureReason: _emptyToNull(rawFailureReason),
          receivedAt: rawReceivedAt == null || rawReceivedAt.isEmpty
              ? null
              : DateTime.tryParse(rawReceivedAt)?.toUtc(),
        ),
      );
    }
    return messages;
  }

  /// Returns a drained message to the native queue after processing failed —
  /// the drain is destructive, so this is what keeps a failing message from
  /// being lost. The native side skips its host wake-up notification to avoid
  /// an immediate drain → fail → re-enqueue loop; the message is retried on
  /// the next resume/launch drain instead. Best-effort: on Android (no handler
  /// yet) or bridge failure the message is dropped exactly as before this fix.
  static Future<bool> reEnqueueSharedMessage(
    SharedCapturedMessage message,
  ) async {
    if (!Platform.isIOS) return false;
    try {
      await _channel.invokeMethod<void>('reEnqueueSharedMessage', {
        'text': message.text,
        'sender': message.sender,
        'senderName': message.senderName,
        'senderId': message.senderId,
        'source': message.source == CapturedMessageSource.iosShortcut
            ? 'ios_shortcut'
            : message.source == CapturedMessageSource.iosShare
                ? 'ios_share'
                : null,
        'receivedAt': message.receivedAt?.toIso8601String(),
        'locale': message.locale,
        'status': message.status,
        'failureReason': message.failureReason,
        'payloadId': message.id,
      });
      return true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<List<CaptureNotificationRoute>>
      consumePendingNotificationRoutes() async {
    if (!Platform.isIOS) return const [];
    final String? json;
    try {
      json = await _channel
          .invokeMethod<String>('consumePendingNotificationRoutes');
    } on MissingPluginException {
      return const [];
    }
    if (json == null || json.trim().isEmpty) return const [];
    final List<dynamic> decoded;
    try {
      decoded = jsonDecode(json) as List<dynamic>;
    } on FormatException {
      return const [];
    }
    return [
      for (final item in decoded)
        if (item is Map)
          CaptureNotificationRoute(
            payloadId: _emptyToNull(_asString(item['payloadId'])),
            transactionId: _emptyToNull(_asString(item['transactionId'])),
            smartInboxItemId: _emptyToNull(_asString(item['smartInboxItemId'])),
            notificationType: _emptyToNull(_asString(item['notificationType'])),
            source: _emptyToNull(_asString(item['source'])),
            receivedAt: item['receivedAt'] is String
                ? DateTime.tryParse(item['receivedAt'] as String)?.toUtc()
                : null,
            notificationLogId:
                _emptyToNull(_asString(item['notificationLogId'])),
          ),
    ];
  }

  /// Drains the iOS Shortcut extension's local notification-scheduling
  /// events (created/sent/failed) recorded via SharedCaptureStore. Returns
  /// an empty list on Android or when nothing is pending.
  static Future<List<NativeNotificationLogEvent>>
      consumePendingNotificationLogEvents() async {
    if (!Platform.isIOS) return const [];
    final String? json;
    try {
      json = await _channel
          .invokeMethod<String>('consumePendingNotificationLogEvents');
    } on MissingPluginException {
      return const [];
    }
    if (json == null || json.trim().isEmpty) return const [];
    final List<dynamic> decoded;
    try {
      decoded = jsonDecode(json) as List<dynamic>;
    } on FormatException {
      return const [];
    }
    return [
      for (final item in decoded)
        if (item is Map &&
            item['notificationLogId'] is String &&
            item['eventType'] is String &&
            item['channel'] is String &&
            item['notificationType'] is String)
          NativeNotificationLogEvent(
            notificationLogId: item['notificationLogId'] as String,
            eventType: item['eventType'] as String,
            channel: item['channel'] as String,
            notificationType: item['notificationType'] as String,
            relatedEntityType:
                _emptyToNull(_asString(item['relatedEntityType'])),
            relatedEntityId: _emptyToNull(_asString(item['relatedEntityId'])),
            errorCode: _emptyToNull(_asString(item['errorCode'])),
            errorReason: _emptyToNull(_asString(item['errorReason'])),
            occurredAt: item['occurredAt'] is String
                ? DateTime.tryParse(item['occurredAt'] as String)?.toUtc()
                : null,
          ),
    ];
  }

  static CapturedMessageSource _iosCapturedSource(String? source) {
    return source == 'ios_shortcut' || source == 'shortcut'
        ? CapturedMessageSource.iosShortcut
        : CapturedMessageSource.iosShare;
  }

  static String? _firstNonEmpty(Iterable<String?> values) {
    for (final value in values) {
      final clean = _emptyToNull(value);
      if (clean != null) return clean;
    }
    return null;
  }

  static String? _emptyToNull(String? value) {
    if (value == null || value.isEmpty) return null;
    return value;
  }

  /// Like a `value as String?` cast, but tolerant of an unexpected JSON type
  /// (e.g. a number) instead of throwing — one malformed field in a decoded
  /// native payload must not take down the whole list comprehension it's
  /// part of. See notification_log_service_test.dart / requirement 9 of the
  /// Phase 1 notification-tracking hardening pass.
  static String? _asString(Object? value) => value is String ? value : null;

  static ApnsTokenInfo? _tokenInfoFrom(Object? value) {
    if (value is! Map) return null;
    final token = _emptyToNull(value['token'] as String?);
    final environment = _emptyToNull(value['environment'] as String?);
    if (token == null || environment == null) return null;
    return ApnsTokenInfo(token: token, environment: environment);
  }

  static ApnsRegistrationFailure? _apnsFailureFrom(Object? value) {
    if (value is! Map) return null;
    final message = _emptyToNull(value['message'] as String?);
    final occurredAtRaw = _emptyToNull(value['occurredAt'] as String?);
    final occurredAt = occurredAtRaw == null
        ? null
        : DateTime.tryParse(occurredAtRaw)?.toUtc();
    if (message == null || occurredAt == null) return null;
    return ApnsRegistrationFailure(
      message: message,
      occurredAt: occurredAt,
      domain: _emptyToNull(value['domain'] as String?),
      code: value['code'] is int ? value['code'] as int : null,
    );
  }
}
