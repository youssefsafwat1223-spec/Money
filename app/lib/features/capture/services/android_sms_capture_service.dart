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

  /// Ask for RECEIVE_SMS **after** the caller has shown the prominent
  /// disclosure, then turn automatic capture on if it was granted.
  ///
  /// [showDisclosure] must present the disclosure and return true only on an
  /// explicit affirmative action. Passing the disclosure in — rather than
  /// trusting callers to show one first — makes the Play-required ordering
  /// structural: there is no path through this method that reaches the system
  /// dialog without the disclosure returning true.
  ///
  /// Declining the disclosure never requests the permission, which matters:
  /// Play treats a permission dialog shown before disclosure as a violation
  /// even if the user then grants it.
  ///
  /// Fails closed everywhere. Non-Android, undeclared, declined, denied, or a
  /// platform error all leave automatic capture OFF, and share capture — which
  /// needs no permission — keeps working in every one of those cases.
  Future<SmsPermissionResult> requestAndEnable({
    required Future<bool> Function() showDisclosure,
  }) async {
    if (!Platform.isAndroid) return SmsPermissionResult.unsupported;

    final caps = await NativeCaptureBridge.captureCapabilities();
    if (!caps.receiveSmsDeclared) return SmsPermissionResult.unsupported;

    // Already granted: no dialog to show, so no disclosure is required — but
    // the opt-in is still a separate, explicit act.
    if (!caps.hasReceiveSmsPermission) {
      final accepted = await showDisclosure();
      if (!accepted) {
        return const SmsPermissionResult(
          status: SmsPermissionStatus.denied,
          declared: true,
          granted: false,
          enabled: false,
        );
      }
    }

    // BOUNDED. `MainActivity.pendingSmsPermissionResult` is an activity-instance
    // field: the manifest declares the usual configuration changes as handled,
    // so an ordinary rotation does not lose it — but if the activity is
    // recreated for any other reason while the system dialog is up, the new
    // instance holds null, `onRequestPermissionsResult` returns early, and this
    // Future never completes. That would leave the Settings switch spinning
    // forever on a permission the user may well have granted.
    //
    // On timeout we do not guess: we re-read the platform's own capability
    // snapshot, which is authoritative for both halves of the two-key lock.
    final result = await NativeCaptureBridge.requestReceiveSmsPermission()
        .timeout(const Duration(minutes: 2), onTimeout: _stateAfterLostResult);
    if (result.status != SmsPermissionStatus.granted) return result;

    final enabled =
        await NativeCaptureBridge.setAutomaticSmsCaptureEnabled(true);
    return SmsPermissionResult(
      status: SmsPermissionStatus.granted,
      declared: true,
      granted: true,
      enabled: enabled,
    );
  }

  /// Recover the real state after a permission result was lost in transit.
  ///
  /// Reports what the platform actually says rather than assuming denial: the
  /// user may have granted the permission before the round trip broke, and
  /// telling them it failed would be as wrong as telling them it worked.
  static Future<SmsPermissionResult> _stateAfterLostResult() async {
    try {
      final caps = await NativeCaptureBridge.captureCapabilities();
      return SmsPermissionResult(
        status: caps.hasReceiveSmsPermission
            ? SmsPermissionStatus.granted
            : SmsPermissionStatus.denied,
        declared: caps.receiveSmsDeclared,
        granted: caps.hasReceiveSmsPermission,
        enabled: caps.isAutomaticSmsCaptureEnabled,
      );
    } catch (_) {
      return SmsPermissionResult.unsupported;
    }
  }

  /// Turn automatic capture off without touching the OS permission.
  ///
  /// Revoking the permission is the user's business in Settings; this is the
  /// in-app off switch, and it must work even while the permission is granted.
  Future<bool> disableAutomaticCapture() => setAutomaticCaptureEnabled(false);

  /// Send the user to the app's system settings page.
  ///
  /// The only route out of `permanentlyDenied` — once "don't ask again" is set,
  /// requesting again returns immediately without showing anything.
  Future<void> openSystemSettings() => NativeCaptureBridge.openAppSettings();
}
