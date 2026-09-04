import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// R8C — the Android compile CI contract.
///
/// Android used to be compiled only by `android-release`, i.e. on release day and
/// behind the real signing inputs, so a plugin/Gradle defect could not be seen
/// until the worst possible moment. These guards keep an Android compile in the
/// ordinary pre-release path and keep it honest: hard-failing, pinned, using the
/// vendored file_picker, and free of production signing/AdMob requirements.
String _ci() => File('../codemagic.yaml').readAsStringSync();

/// The body of one named Codemagic workflow, so assertions about the quality
/// gate cannot be satisfied by text belonging to the release workflow.
String _workflow(String name) {
  final ci = _ci();
  final start = ci.indexOf('  $name:');
  expect(start, greaterThan(-1), reason: 'workflow $name not found');
  final next = RegExp(r'\n  [a-z][a-z0-9-]*:\n').firstMatch(ci.substring(start + 1));
  return next == null
      ? ci.substring(start)
      : ci.substring(start, start + 1 + next.start);
}

void main() {
  group('pre-release Android compile coverage', () {
    test('the canonical quality workflow compiles Android', () {
      final quality = _workflow('backend-and-quality-gates');
      expect(quality, contains('flutter build apk --debug'),
          reason: 'an Android compile must run before release day, not on it');
      expect(quality, contains('Android compile gate'));
    });

    test('the gate is hard — never allow-failure or ignored', () {
      final quality = _workflow('backend-and-quality-gates');
      for (final soft in const [
        'ignore_failure',
        'allow_failure',
        'continue-on-error',
        '|| true',
      ]) {
        expect(quality.contains(soft), isFalse,
            reason: 'the Android gate must fail the build: found "$soft"');
      }
      // `set -eu` means an intermediate failure aborts rather than continuing.
      expect(quality, contains('set -eu'));
    });

    test('the gate proves the artifact exists, not just the exit code', () {
      final quality = _workflow('backend-and-quality-gates');
      expect(quality, contains('build/app/outputs/flutter-apk/app-debug.apk'));
    });
  });

  // Added 2026-09-03. iOS had the identical gap and it was hiding a real break:
  // `Cannot find 'SharedOfferIntentStore' in scope` — a share-extension type in
  // no build target, invisible because BOTH Xcode workflows are manual-only and
  // nothing here had ever compiled iOS. Same defect class and same feature as
  // the Android package bug. These assertions exist so the gate that caught it
  // cannot be quietly dropped.
  group('pre-release iOS compile coverage', () {
    test('the canonical quality workflow compiles iOS', () {
      final quality = _workflow('backend-and-quality-gates');
      expect(quality, contains('flutter build ios --debug --no-codesign'),
          reason: 'an iOS compile must run before release day, not on it');
      expect(quality, contains('iOS compile gate'));
    });

    test('the iOS gate needs no signing identity', () {
      // The point of --no-codesign: Apple portal access and the provisioning
      // profile are BLOCKED external dependencies. A gate that needed them
      // could never run, so it would be disabled and the coverage lost.
      final quality = _workflow('backend-and-quality-gates');
      expect(quality, contains('--no-codesign'));
      for (final signing in const [
        'CERTIFICATE_PRIVATE_KEY',
        'APP_STORE_CONNECT',
        'xcode-project use-profiles',
      ]) {
        expect(quality.contains(signing), isFalse,
            reason: 'the iOS gate must not depend on signing: found "$signing"');
      }
    });

    test('the gate proves the app AND the embedded extension were built', () {
      // The defect lived in the share extension, which is a separate binary. A
      // Runner.app produced without its .appex would read as success.
      final quality = _workflow('backend-and-quality-gates');
      expect(quality, contains('build/ios/iphoneos/Runner.app'));
      expect(quality, contains('PlugIns/ShareBankMessage.appex'));
    });
  });

  group('toolchain pinning', () {
    test('Flutter and JDK are pinned on the compile workflow', () {
      final quality = _workflow('backend-and-quality-gates');
      expect(quality, contains('flutter: 3.44.2'),
          reason: 'the compile must reproduce the locally proven Flutter');
      expect(quality, contains('java: 17'),
          reason: 'AGP 9 + jvmTarget 17 require JDK 17');
    });

    test('the pinned NDK is installed rather than assumed', () {
      final quality = _workflow('backend-and-quality-gates');
      expect(quality, contains('28.2.13676358'),
          reason: 'sqlite3mc is a native asset; the NDK version must be explicit');
    });

    test('the project toolchain itself is unchanged', () {
      final settings =
          File('android/settings.gradle.kts').readAsStringSync();
      expect(settings, contains('"9.0.1"'), reason: 'AGP');
      expect(settings, contains('"2.3.20"'), reason: 'Kotlin');
      final wrapper = File('android/gradle/wrapper/gradle-wrapper.properties')
          .readAsStringSync();
      expect(wrapper, contains('gradle-9.1.0'));
    });
  });

  group('the gate uses the vendored file_picker', () {
    test('CI refuses to build if resolution falls back to pub.dev', () {
      final quality = _workflow('backend-and-quality-gates');
      expect(quality, contains('path: ../third_party/file_picker'),
          reason: 'CI must assert the vendored fork is wired');
      expect(quality, contains('QIRSH_FORK.md'),
          reason: 'the failure message should point at the provenance doc');
    });

    test('the companion dependencies stay unmigrated', () {
      final lock = File('pubspec.lock').readAsStringSync();
      expect(lock, contains('version: "10.1.4"'), reason: 'share_plus');
      expect(lock, contains('version: "9.2.4"'), reason: 'flutter_secure_storage');
      expect(RegExp(r'name: win32\n(?:.*\n)*?    version: "6\.').hasMatch(lock),
          isFalse, reason: 'win32 must stay on 5.x');
    });
  });

  // Added 2026-09-04 while reconciling the iOS release config. These are about
  // what a SUCCESSFUL build does, which is the part nobody looks at until it has
  // already happened.
  group('iOS release config safety', () {
    test('a successful signed build does NOT auto-submit to Apple', () {
      // `submit_to_testflight: true` uploads on EVERY successful run. Submission
      // is not authorised, no iOS build has ever run on a physical device, and
      // until 2026-09-03 iOS did not compile at all. Publishing as a side effect
      // of succeeding is the wrong default; the IPA is an artifact until someone
      // decides otherwise.
      final ios = _workflow('ios-signed-release');
      expect(ios.contains('submit_to_testflight: true'), isFalse,
          reason: 'auto-submit to TestFlight must stay off until submission is '
              'explicitly authorised — flip it deliberately, not by inheriting '
              'a default');
    });

    test('release config carries no placeholder bundle identifier', () {
      // The template id (com.example.*) shipping in a release config is the iOS
      // analogue of the Kotlin package bug: it looks fine until an artifact is
      // signed and rejected, or worse, accepted under the wrong identity.
      final ci = File('../codemagic.yaml').readAsStringSync();
      expect(ci.contains('com.example'), isFalse,
          reason: 'codemagic.yaml contains a com.example placeholder id');
      expect(ci.contains('moneyCompanion'), isFalse,
          reason: 'codemagic.yaml contains the stale moneyCompanion id');
      expect(ci, contains('bundle_identifier: com.youssefsafwat.mali'),
          reason: 'the signed iOS workflow must name the authoritative bundle id');
    });

    test('every iOS bundle id in the Xcode project is under the app id', () {
      // Runner, the share extension and the test host. The extension is a
      // separate signed binary and needs its own App ID and profile; a stale one
      // here fails at export, long after the compile that looked fine.
      final pbx =
          File('ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();
      final ids = RegExp(r'PRODUCT_BUNDLE_IDENTIFIER = ([^;]+);')
          .allMatches(pbx)
          .map((m) => m.group(1)!.trim())
          .toSet();
      expect(ids, isNotEmpty);
      for (final id in ids) {
        expect(id.startsWith('com.youssefsafwat.mali'), isTrue,
            reason: 'unexpected iOS bundle identifier: $id');
      }
    });
  });

  group('separation of responsibilities', () {
    test('the compile gate needs no signing key', () {
      final quality = _workflow('backend-and-quality-gates');
      for (final secret in const [
        'ANDROID_KEYSTORE_BASE64',
        'ANDROID_KEYSTORE_PASSWORD',
        'ANDROID_KEY_ALIAS',
        'ANDROID_KEY_PASSWORD',
        'google_play',
      ]) {
        expect(quality.contains(secret), isFalse,
            reason: 'a debug compile must not require $secret');
      }
    });

    test('the compile gate needs no production AdMob configuration', () {
      final quality = _workflow('backend-and-quality-gates');
      for (final v in const ['ADMOB_APP_ID_ANDROID', 'ADMOB_INTERSTITIAL_ANDROID']) {
        expect(quality.contains(v), isFalse,
            reason: 'ordinary verification must not need production $v');
      }
    });

    test('the release workflow still demands explicit signing inputs', () {
      final release = _workflow('android-release');
      expect(release, contains('ANDROID_KEYSTORE_BASE64'));
      expect(release, contains('Materialise upload keystore'));
      expect(release, contains('flutter build appbundle --release'),
          reason: 'the real Play artifact stays in the release workflow');
    });

    test('GitHub Actions stays verification-only (no Android secrets)', () {
      final gha = File('../.github/workflows/ci.yml').readAsStringSync();
      expect(gha, contains('ci_gates.sh'));
      for (final secret in const [
        'ANDROID_KEYSTORE_BASE64',
        'ANDROID_KEY_PASSWORD',
      ]) {
        expect(gha.contains(secret), isFalse,
            reason: 'do not duplicate release secrets into GitHub: $secret');
      }
    });
  });

  group('ci_gates.sh boundary', () {
    // Deliberate: ci_gates.sh must stay portable. Forcing every local run to
    // fetch a ~3 GB NDK would destroy its usefulness, so the Android compile
    // lives in the CI workflow as a second mandatory stage instead.
    test('the portable local suite does not require Android tooling', () {
      final gates = File('../tools/ci_gates.sh').readAsStringSync();
      for (final heavy in const [
        'flutter build apk',
        'flutter build appbundle',
        'sdkmanager',
        'gradlew',
      ]) {
        expect(gates.contains(heavy), isFalse,
            reason: 'ci_gates.sh must stay portable: found "$heavy"');
      }
    });
  });

  group('release workflow ordering (§13)', () {
    test('the artifact signer is inspected before the key is shredded', () {
      final release = _workflow('android-release');
      expect(release, contains('Inspect release artifact signer'));
      expect(release.indexOf('Build release App Bundle'),
          lessThan(release.indexOf('Inspect release artifact signer')),
          reason: 'inspect after building');
      expect(release.indexOf('Inspect release artifact signer'),
          lessThan(release.indexOf('Shred materialised keystore')),
          reason: 'inspect before the key disappears');
    });

    test('a debug-signed or unsigned artifact fails the release', () {
      final release = _workflow('android-release');
      expect(release, contains('Android Debug'),
          reason: 'the debug certificate must be explicitly rejected');
      expect(release, contains('is not signed'));
    });
  });
}
