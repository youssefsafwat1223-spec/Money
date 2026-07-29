import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';

// MALI-013: capture-capability reporting. Verifies the honest model that
// replaced the old hasSmsPermission() (which mislabelled notification perm as
// SMS). The native channel invoke is platform-gated (Android only); this
// exercises the JSON contract the native side emits.
void main() {
  test('share capture is always available, even with no SMS permission', () {
    final caps = CaptureCapabilities.fromJson(const {
      'supportsShareCapture': true,
      'receiveSmsDeclared': false,
      'hasReceiveSmsPermission': false,
      'canUseAutomaticSmsCapture': false,
      'isAutomaticSmsCaptureEnabled': false,
      'hasNotificationPermission': true,
    });
    expect(caps.supportsShareCapture, isTrue);
    expect(caps.canUseAutomaticSmsCapture, isFalse);
  });

  test('notification permission is NEVER reported as SMS permission', () {
    // Notifications granted, SMS not — the exact confusion the old API made.
    final caps = CaptureCapabilities.fromJson(const {
      'hasNotificationPermission': true,
      'hasReceiveSmsPermission': false,
      'receiveSmsDeclared': false,
      'canUseAutomaticSmsCapture': false,
    });
    expect(caps.hasNotificationPermission, isTrue);
    expect(caps.hasReceiveSmsPermission, isFalse);
    expect(caps.canUseAutomaticSmsCapture, isFalse);
  });

  test('a Play-safe build (SMS not declared) cannot use automatic capture', () {
    final caps = CaptureCapabilities.fromJson(const {
      'supportsShareCapture': true,
      'receiveSmsDeclared': false,
      'hasReceiveSmsPermission': false,
      'canUseAutomaticSmsCapture': false,
    });
    expect(caps.receiveSmsDeclared, isFalse);
    expect(caps.canUseAutomaticSmsCapture, isFalse);
    // Share remains the fallback.
    expect(caps.supportsShareCapture, isTrue);
  });

  test('declared + granted + enabled reports full automatic capability', () {
    final caps = CaptureCapabilities.fromJson(const {
      'supportsShareCapture': true,
      'receiveSmsDeclared': true,
      'hasReceiveSmsPermission': true,
      'canUseAutomaticSmsCapture': true,
      'isAutomaticSmsCaptureEnabled': true,
      'hasNotificationPermission': true,
    });
    expect(caps.canUseAutomaticSmsCapture, isTrue);
    expect(caps.isAutomaticSmsCaptureEnabled, isTrue);
  });

  test('granted but not enabled: capable, but off (opt-in default)', () {
    final caps = CaptureCapabilities.fromJson(const {
      'receiveSmsDeclared': true,
      'hasReceiveSmsPermission': true,
      'canUseAutomaticSmsCapture': true,
      'isAutomaticSmsCaptureEnabled': false,
    });
    expect(caps.canUseAutomaticSmsCapture, isTrue);
    expect(caps.isAutomaticSmsCaptureEnabled, isFalse);
  });

  test('malformed/empty payload falls back to share-only defaults', () {
    final caps = CaptureCapabilities.fromJson(const {});
    expect(caps.supportsShareCapture, isTrue); // safe default
    expect(caps.hasReceiveSmsPermission, isFalse);
    expect(caps.canUseAutomaticSmsCapture, isFalse);
    expect(caps.isAutomaticSmsCaptureEnabled, isFalse);
    expect(caps.hasNotificationPermission, isFalse);
  });
}
