import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Keychain accessibility is a property of every WRITE, so one forgotten
/// constructor is enough to put a secret back into iCloud Keychain.
///
/// `FlutterSecureStorage()` with no options means
/// `kSecAttrAccessibleWhenUnlocked` without `ThisDeviceOnly` on iOS — eligible
/// for iCloud Keychain and device-to-device transfer. Twelve sites had it,
/// including the SQLCipher database key, the capture relay secret and the
/// install id.
///
/// This guard is deliberately a source scan, which is the weaker kind of
/// evidence: it says the constructor is not used, not that the resulting
/// keychain item is device-bound. The behavioural half lives in
/// `integration_test/keychain_accessibility_test.dart`, which writes and reads
/// against a real simulator keychain and proves the upgrade and rollback paths.
void main() {
  /// Sites that may keep the bare constructor, with the reason.
  const allowed = <String, String>{
    'lib/core/security/secure_storage_options.dart':
        'defines the options; the mentions are in its own documentation',
    'lib/features/dashboard/dashboard_screen.dart':
        'stores `setup_nudge_snoozed_until`, a UI snooze timestamp and not a '
            'secret. Left alone because this file carries substantial '
            'uncommitted owner work that must stay byte-identical — the two '
            'sites are recorded here so the exemption is a decision rather '
            'than an oversight, and they should adopt the shared options '
            'whenever that work lands.',
  };

  test('no new bare FlutterSecureStorage() creeps in', () {
    final offenders = <String>[];
    void walk(Directory dir) {
      for (final e in dir.listSync()) {
        if (e is Directory) {
          walk(e);
        } else if (e is File && e.path.endsWith('.dart')) {
          final rel = e.path.replaceFirst(RegExp(r'^\./'), '');
          if (allowed.containsKey(rel)) continue;
          if (e.readAsStringSync().contains('FlutterSecureStorage()')) {
            offenders.add(rel);
          }
        }
      }
    }

    walk(Directory('lib'));
    expect(
      offenders,
      isEmpty,
      reason: 'these construct secure storage with platform defaults, which on '
          'iOS leaves the item eligible for iCloud Keychain:\n'
          '  ${offenders.join('\n  ')}\n\n'
          'Use SecureStorageOptions.storage, or add the file to `allowed` WITH '
          'the reason it holds nothing secret.',
    );
  });

  test('the shared options are ThisDeviceOnly and survive a locked device', () {
    final src =
        File('lib/core/security/secure_storage_options.dart').readAsStringSync();
    // `first_unlock_this_device` maps to
    // kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly. ThisDeviceOnly is the
    // half that keeps the key off iCloud; afterFirstUnlock is the half that
    // lets the capture pipeline and scheduled notifications keep working while
    // the phone is locked. `whenUnlocked` would break them.
    expect(src, contains('KeychainAccessibility.first_unlock_this_device'));
  });

  test('every allowed exemption states a reason and still exists', () {
    for (final entry in allowed.entries) {
      expect(File(entry.key).existsSync(), isTrue,
          reason: '${entry.key} is exempted but no longer exists; prune it');
      expect(entry.value.trim(), isNotEmpty);
    }
  });
}
