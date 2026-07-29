import 'dart:io';

import 'native_capture_bridge.dart';

/// MALI-013 — Android capture capability facade.
///
/// Replaces the old no-op stub (methods that returned `false`/did nothing while
/// implying a working SMS listener). Capture on Android has two modes:
///   • Share to Mali — always available, durable, needs no permission.
///   • Automatic bank-SMS — opt-in and OFF by default; runs only when the build
///     declares RECEIVE_SMS, the OS grants it, AND the user enables it.
/// This service only reports/toggles capability; received/shared messages flow
/// through the durable native queue and the existing peek/ack import pipeline.
class AndroidSmsCaptureService {
  AndroidSmsCaptureService._();

  static final AndroidSmsCaptureService instance = AndroidSmsCaptureService._();

  /// Honest capability snapshot (share vs automatic vs notification), never
  /// conflating notification permission with SMS.
  Future<CaptureCapabilities> capabilities() {
    return NativeCaptureBridge.captureCapabilities();
  }

  /// Share capture is always available (even with SMS denied/absent).
  bool get supportsShareCapture => true;

  /// Enable/disable automatic SMS capture. Returns the EFFECTIVE state — always
  /// false unless the build declares + the OS grants RECEIVE_SMS, regardless of
  /// what was requested. On non-Android platforms this is always false.
  Future<bool> setAutomaticCaptureEnabled(bool enabled) {
    if (!Platform.isAndroid) return Future.value(false);
    return NativeCaptureBridge.setAutomaticSmsCaptureEnabled(enabled);
  }
}
