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
