import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

/// A single bank message drained from the native share queue.
class SharedCapturedMessage {
  const SharedCapturedMessage({required this.text, this.sender});

  final String text;
  final String? sender;
}

class NativeCaptureBridge {
  NativeCaptureBridge._();

  static const MethodChannel _channel =
      MethodChannel('money_companion/native_capture');

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

  static Future<String?> consumePendingSharedInput() async {
    if (!Platform.isIOS) {
      return null;
    }
    final text = await _channel.invokeMethod<String>('consumePendingSharedInput');
    if (text == null || text.trim().isEmpty) {
      return null;
    }
    return text;
  }

  /// Drains the full FIFO queue of bank messages captured by native sharing
  /// surfaces: iOS Share Extension/App Intent and Android ACTION_SEND.
  static Future<List<SharedCapturedMessage>> consumePendingSharedMessages() async {
    if (!Platform.isIOS && !Platform.isAndroid) {
      return const [];
    }
    final json =
        await _channel.invokeMethod<String>('consumePendingSharedMessages');
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
      final rawSender = (item['sender'] as String?)?.trim();
      messages.add(
        SharedCapturedMessage(
          text: text,
          sender: (rawSender == null || rawSender.isEmpty) ? null : rawSender,
        ),
      );
    }
    return messages;
  }
}
