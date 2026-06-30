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

class NativeCaptureBridge {
  NativeCaptureBridge._();

  static const MethodChannel _channel =
      MethodChannel('money_companion/native_capture');
  static Future<void> Function()? _pendingMessagesHandler;

  static void setPendingMessagesHandler(
    Future<void> Function()? handler,
  ) {
    _pendingMessagesHandler = handler;
    if (handler == null) {
      _channel.setMethodCallHandler(null);
      return;
    }
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'pendingSharedMessagesAvailable') {
        await _pendingMessagesHandler?.call();
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
  static Future<List<SharedCapturedMessage>>
      consumePendingSharedMessages() async {
    if (!Platform.isIOS && !Platform.isAndroid) {
      return const [];
    }
    final String? json;
    try {
      json =
          await _channel.invokeMethod<String>('consumePendingSharedMessages');
    } on MissingPluginException {
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

  static CapturedMessageSource _iosCapturedSource(String? source) {
    return source == 'shortcut'
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
}
