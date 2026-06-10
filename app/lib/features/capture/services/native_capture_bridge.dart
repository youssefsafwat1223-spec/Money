import 'dart:io';

import 'package:flutter/services.dart';

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
}
