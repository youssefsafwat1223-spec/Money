import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// MALI-043 / MALI-031 — STATIC iOS privacy-manifest contract (source-level, not
// the built .app bundle; freshly-built archive evidence is external and lives in
// tools/verify_ios_packaging.sh). A permission usage-description string in
// Info.plist is a privacy/App-Store surface: declaring one the app cannot
// justify (no code / package / capability) is a store-review risk and a false
// privacy signal. This is a PRECISE structural guard for the known location keys
// plus a JUSTIFIED-usage inventory (an allowlist), not a fragile
// "every key maps to code" heuristic.

void main() {
  final plist = File('ios/Runner/Info.plist').readAsStringSync();

  RegExp key(String k) => RegExp('<key>$k</key>');

  group('iOS Info.plist permission usage descriptions', () {
    // The app has no location package and no location code (MALI-043): a
    // location usage-description must never reappear.
    const locationKeys = [
      'NSLocationWhenInUseUsageDescription',
      'NSLocationAlwaysAndWhenInUseUsageDescription',
      'NSLocationAlwaysUsageDescription',
      'NSLocationUsageDescription',
    ];
    for (final k in locationKeys) {
      test('$k is absent (no location feature exists)', () {
        expect(key(k).hasMatch(plist), isFalse,
            reason:
                'the app declares no location capability — $k is an unjustified '
                'permission and an App-Store-review risk');
      });
    }

    // Inventory guard: every NS*UsageDescription present must be one the app
    // actually justifies. A NEW unjustified permission (contacts, mic, calendar,
    // location, …) added later fails here until it is either justified and
    // allowlisted or removed.
    test('only justified usage-description keys are declared', () {
      const justified = {
        'NSCameraUsageDescription', // profile photo capture
        'NSFaceIDUsageDescription', // biometric app lock
        'NSPhotoLibraryUsageDescription', // profile photo selection
      };
      final present = RegExp(r'<key>(NS\w*UsageDescription)</key>')
          .allMatches(plist)
          .map((m) => m.group(1)!)
          .toSet();
      final unjustified = present.difference(justified);
      expect(unjustified, isEmpty,
          reason: 'unjustified permission usage-description(s) declared: '
              '$unjustified — justify + allowlist them here, or remove them');
    });
  });
}
