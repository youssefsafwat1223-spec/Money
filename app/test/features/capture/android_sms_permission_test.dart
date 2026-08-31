import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';

/// MALI-013 — Android automatic financial-SMS capture.
///
/// Play treats `RECEIVE_SMS` as a restricted permission and grants an exception
/// only for SMS-based money management. Everything asserted here is something
/// the review checks or something whose regression would be invisible:
///
///   • the manifest asks for RECEIVE_SMS and nothing wider,
///   • the receiver can only be reached by the OS,
///   • a granted permission is not treated as consent,
///   • the privacy-filter rule has not been loosened back to `amount OR keyword`,
///   • the privacy policy describes what actually ships.
///
/// The Kotlin filter itself has no unit test: the project has no JVM or
/// instrumentation test source set for Android, so these are structural
/// assertions over the source instead. That is weaker than executing it and is
/// recorded as such in `Qirsh Production/18_Android_SMS_Capture/`.
void main() {
  final manifest =
      File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
  // Comments are load-bearing here: the permission spent months commented out,
  // and a naive grep reported it as present the whole time.
  final effective = manifest.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');

  group('effective release manifest', () {
    test('RECEIVE_SMS is declared', () {
      expect(effective, contains('android.permission.RECEIVE_SMS'),
          reason: 'automatic capture is a core V1 feature');
    });

    test('no wider SMS permission is requested', () {
      // Each of these enlarges the Play declaration and none is used by the
      // implementation, which reads broadcast intents only.
      for (final permission in const [
        'READ_SMS',
        'SEND_SMS',
        'WRITE_SMS',
        'RECEIVE_MMS',
        'RECEIVE_WAP_PUSH',
      ]) {
        expect(effective.contains(permission), isFalse,
            reason: '$permission is not used and must not be declared');
      }
    });

    test('no NotificationListenerService', () {
      // Documentation claimed one for months. There has never been one, and
      // declaring it would invite a second restricted-permission review.
      expect(effective.contains('NotificationListener'), isFalse);
    });

    test('the SMS receiver is declared and OS-only', () {
      expect(effective, contains('.SmsCaptureReceiver'));
      expect(effective, contains('android.provider.Telephony.SMS_RECEIVED'));
      // Without BROADCAST_SMS any app could inject a fake bank SMS.
      expect(effective, contains('android:permission="android.permission.BROADCAST_SMS"'));
    });

    test('the receiver is manifest-declared, not runtime-registered', () {
      // It must start when the process is not running; a runtime-registered
      // receiver cannot, which would silently break closed-app capture.
      expect(effective, contains('<receiver'));
    });
  });

  group('native gating', () {
    final settings = File(
      'android/app/src/main/kotlin/com/example/money_companion/CaptureSettings.kt',
    ).readAsStringSync();

    test('a granted permission is not consent — opt-in defaults to false', () {
      expect(settings, contains('getBoolean(KEY_AUTO_ENABLED, false)'));
    });

    test('revocation fails capture closed', () {
      // isAutoCaptureEnabled re-checks the permission every call, so revoking
      // in system settings stops capture without the app being involved.
      expect(settings, contains('if (!hasReceiveSmsPermission(context)) return false'));
    });

    test('opt-in is reset on identity change', () {
      expect(settings, contains('fun reset('));
    });
  });

  group('receiver privacy prefilter', () {
    final receiver = File(
      'android/app/src/main/kotlin/com/example/money_companion/SmsCaptureReceiver.kt',
    ).readAsStringSync();

    test('filtering happens before anything is enqueued', () {
      final filterAt = receiver.indexOf('shouldRetain(');
      final enqueueAt = receiver.indexOf('.enqueue(');
      expect(filterAt, greaterThan(-1));
      expect(filterAt, lessThan(enqueueAt),
          reason: 'a non-financial message must never reach durable storage');
    });

    test('the rule is sender-aware, not a flat OR', () {
      // The previous rule was `hasAmount || hasKeyword` for every sender, so a
      // personal message containing "card" was retained. Numeric senders — where
      // personal messages come from — now require both signals.
      expect(receiver, contains('isAlphanumericSender'));
      expect(receiver, contains('hasAmount || hasKeyword'));
      expect(receiver, contains('hasAmount && hasKeyword'));
    });

    test('an unknown sender takes the strict path', () {
      // Absent evidence must not buy the loose rule.
      expect(receiver, contains('if (s.isEmpty()) return false'));
    });

    test('one-time codes are dropped', () {
      expect(receiver, contains('isLikelyOtp'));
    });

    test('the prefilter does not become a second parser', () {
      // The authoritative parse lives in the Dart engine. Anything resembling
      // extraction here would drift from it and be invisible when it did.
      for (final smell in const ['ParsedTransaction', 'amountValue', 'merchant']) {
        expect(receiver.contains(smell), isFalse,
            reason: 'the receiver must classify, never extract');
      }
    });

    test('multipart reconstruction and the SMS timestamp are preserved', () {
      expect(receiver, contains('for (part in messages)'));
      expect(receiver, contains('timestampMillis'));
    });
  });

  group('permission result contract', () {
    test('denied and permanently denied are distinguishable', () {
      // They need different UX: one can retry the dialog, the other can only be
      // resolved in system settings. Collapsing them yields a button that
      // silently does nothing.
      expect(
        SmsPermissionResult.fromJson(const {'status': 'denied'}).status,
        SmsPermissionStatus.denied,
      );
      expect(
        SmsPermissionResult.fromJson(const {'status': 'permanently_denied'})
            .status,
        SmsPermissionStatus.permanentlyDenied,
      );
    });

    test('granted permission is reported separately from enablement', () {
      final r = SmsPermissionResult.fromJson(
        const {'status': 'granted', 'granted': true, 'enabled': false},
      );
      expect(r.granted, isTrue);
      expect(r.enabled, isFalse,
          reason: 'permission granted is not the same as user opt-in');
    });

    test('an unknown status fails closed', () {
      final r = SmsPermissionResult.fromJson(const {'status': 'nonsense'});
      expect(r.status, SmsPermissionStatus.unavailable);
      expect(r.granted, isFalse);
      expect(r.enabled, isFalse);
    });
  });

  group('disclosure ordering', () {
    final service = File(
      'lib/features/capture/services/android_sms_capture_service.dart',
    ).readAsStringSync();

    test('the disclosure is a required parameter, not a convention', () {
      // Passing it in makes the Play-required ordering structural: there is no
      // path to the system dialog that skips it.
      expect(service, contains('required Future<bool> Function() showDisclosure'));
    });

    test('declining never requests the permission', () {
      final declineAt = service.indexOf('if (!accepted)');
      final requestAt = service.indexOf('requestReceiveSmsPermission()');
      expect(declineAt, greaterThan(-1));
      expect(declineAt, lessThan(requestAt));
    });

    test('capture is only enabled after a granted result', () {
      final guardAt =
          service.indexOf('if (result.status != SmsPermissionStatus.granted)');
      final enableAt = service.indexOf('setAutomaticSmsCaptureEnabled(true)');
      expect(guardAt, greaterThan(-1));
      expect(guardAt, lessThan(enableAt));
    });
  });

  group('other platforms and paths are unaffected', () {
    test('share capture needs no permission', () {
      final settings = File(
        'android/app/src/main/kotlin/com/example/money_companion/CaptureSettings.kt',
      ).readAsStringSync();
      expect(settings, contains('fun supportsShareCapture(): Boolean = true'));
    });

    test('the automatic path is Android-only', () {
      final service = File(
        'lib/features/capture/services/android_sms_capture_service.dart',
      ).readAsStringSync();
      expect(service, contains('if (!Platform.isAndroid)'));
    });

    test('iOS declares no SMS capability', () {
      final plist = File('ios/Runner/Info.plist').readAsStringSync();
      expect(plist.contains('SMS'), isFalse);
    });
  });

  group('privacy policy matches what ships', () {
    final policy = File('../docs/legal/PRIVACY_POLICY.md').readAsStringSync();

    test('SMS access is disclosed', () {
      expect(policy, contains('RECEIVE_SMS'));
      expect(policy.toLowerCase(), contains('incoming sms'));
    });

    test('the stale notification-access claim is gone', () {
      // There has never been a NotificationListenerService; the policy claimed
      // notification access was the core permission.
      expect(policy.contains('Notification access'), isFalse);
    });

    test('it states the two-key lock and the off switch', () {
      // Matched on fragments, not full sentences: the source is hard-wrapped
      // Markdown with inline emphasis, so a sentence match would fail on
      // reflow or on a `**bold**` marker rather than on meaning.
      expect(policy.toLowerCase(), contains('enough on its own'));
      expect(policy.toLowerCase(), contains('automatic capture stays'));
      expect(policy.toLowerCase(), contains('revoke the permission'));
    });

    test('it does not overclaim that data can never leave the device', () {
      // An optional consented cloud path exists; claiming otherwise would be a
      // false privacy promise, which is worse than no promise.
      expect(policy.toLowerCase(), contains('cloud sync'));
    });
  });
}
