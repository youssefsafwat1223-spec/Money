library liquid_glass_helper;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class LiquidGlassHelper {
  LiquidGlassHelper._();

  static const MethodChannel _channel = MethodChannel('native_liquid_tab_bar');

  static Future<bool> isLiquidGlassSupported() async {
    if (defaultTargetPlatform != TargetPlatform.iOS) return false;
    try {
      return await _channel.invokeMethod<bool>('isLiquidGlassSupported') ??
          false;
    } on PlatformException {
      return false;
    }
  }
}
