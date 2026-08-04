import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// MALI-033 — Android Auto Backup / device-transfer must be disabled, because
/// the entire local dataset is Keystore-bound (a restored SQLCipher DB is
/// undecryptable) and the raw-SMS capture queue must not survive onto another
/// device/user. Static manifest verification (the Android SDK is not available
/// to build; device restore is an external gate).
void main() {
  final manifest =
      File('android/app/src/main/AndroidManifest.xml').readAsStringSync();

  test('platform backup is disabled on <application>', () {
    expect(manifest.contains('android:allowBackup="false"'), isTrue,
        reason: 'allowBackup must be false — no Android Auto Backup of the '
            'Keystore-bound DB / raw-SMS queue.');
    expect(manifest.contains('android:fullBackupContent="false"'), isTrue,
        reason: 'legacy full-backup must also be disabled.');
  });

  test('the backup rationale documents the sensitive artifacts', () {
    // Guards the classification against silent regressions.
    expect(manifest.contains('money_companion.sqlite'), isTrue);
    expect(manifest.contains('mali_capture_queue_v1'), isTrue);
    expect(manifest.contains('FlutterSecureStorage'), isTrue);
  });
}
