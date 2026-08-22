import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// R7 A2 — Android release signing contract.
///
/// These are semantic/scoped assertions on the signing model, not whitespace
/// regexes: the point is that a shipping release can never be signed with the
/// debug key and that no key material is ever committed.
String _read(String path) {
  final f = File(path);
  expect(f.existsSync(), isTrue, reason: 'missing $path');
  return f.readAsStringSync();
}

/// The `release { … }` block of the app module, isolated so assertions about
/// release behaviour cannot accidentally be satisfied by debug config.
String _releaseBlock(String gradle) {
  final start = gradle.indexOf(RegExp(r'buildTypes\s*\{'));
  expect(start, greaterThan(-1), reason: 'buildTypes block not found');
  final rel = gradle.indexOf(RegExp(r'release\s*\{'), start);
  expect(rel, greaterThan(-1), reason: 'release build type not found');
  return gradle.substring(rel, gradle.indexOf('\n    }', rel));
}

void main() {
  const gradlePath = 'android/app/build.gradle.kts';
  const codemagicPath = '../codemagic.yaml';

  group('Gradle release signing', () {
    test('release NEVER falls back to the debug signing config', () {
      final release = _releaseBlock(_read(gradlePath));
      expect(release.contains('signingConfigs.getByName("debug")'), isFalse);
      expect(release.contains('getByName("debug")'), isFalse,
          reason: 'a debug key must never sign a shipping release');
    });

    test('release signing resolves only from explicit inputs', () {
      final gradle = _read(gradlePath);
      for (final name in const [
        'ANDROID_KEYSTORE_PATH',
        'ANDROID_KEYSTORE_PASSWORD',
        'ANDROID_KEY_ALIAS',
        'ANDROID_KEY_PASSWORD',
      ]) {
        expect(gradle, contains(name), reason: 'missing input $name');
      }
      // Every credential comes from env/properties, never a literal.
      expect(gradle, contains('System.getenv('));
      expect(
        RegExp(r'''storePassword\s*=\s*["'][^"'$]''').hasMatch(gradle),
        isFalse,
        reason: 'no literal store password may be committed',
      );
      expect(
        RegExp(r'''keyPassword\s*=\s*["'][^"'$]''').hasMatch(gradle),
        isFalse,
        reason: 'no literal key password may be committed',
      );
    });

    test('a release build without signing inputs fails loudly', () {
      final gradle = _read(gradlePath);
      expect(gradle, contains('hasReleaseSigningConfig'));
      expect(gradle, contains('throw GradleException'),
          reason: 'missing inputs must fail the release task, not warn');
      // The guard must cover the tasks `flutter build apk|appbundle` invoke.
      for (final task in const ['assemble', 'bundle', 'package']) {
        expect(gradle, contains('name.startsWith("$task")'), reason: task);
      }
    });

    test('debug builds keep normal debug signing (unaffected)', () {
      final gradle = _read(gradlePath);
      // No release-only requirement is imposed on debug: the failure hook is
      // scoped to *Release tasks only.
      expect(gradle, contains('name.contains("Release")'),
          reason: 'the failure hook must be release-scoped');
    });
  });

  group('no key material is committed', () {
    test('.gitignore covers keystores and key.properties', () {
      final ignore = _read('android/.gitignore');
      for (final pattern in const ['key.properties', '*.keystore', '*.jks']) {
        expect(ignore, contains(pattern), reason: pattern);
      }
    });

    test('no keystore/credential files exist in the android tree', () {
      final offenders = Directory('android')
          .listSync(recursive: true)
          .whereType<File>()
          .map((f) => f.path)
          .where((p) =>
              p.endsWith('.jks') ||
              p.endsWith('.keystore') ||
              p.endsWith('key.properties')) // the .example is fine
          .toList();
      expect(offenders, isEmpty, reason: 'key material present: $offenders');
    });
  });

  group('CI materialisation contract', () {
    test('the release pipeline materialises the keystore from a secret', () {
      final ci = _read(codemagicPath);
      expect(ci, contains('ANDROID_KEYSTORE_BASE64'),
          reason: 'the upload key must arrive as a CI secret');
      expect(ci, contains('base64 --decode'));
      // Written to the ephemeral CI workspace — never the repo, never a fixed
      // machine path.
      expect(ci, contains(r'${CM_BUILD_DIR}/upload-keystore.jks'));
      expect(ci, contains('ANDROID_KEYSTORE_PATH='),
          reason: 'the decoded path must be exported for Gradle');
      expect(ci, contains('rm -f'), reason: 'material must be shredded after use');
    });

    test('materialisation fails closed when inputs are absent', () {
      final ci = _read(codemagicPath);
      expect(ci, contains('missing Android release signing input'));
      expect(ci, contains('never be signed with the debug key'));
    });

    test('no secret value is ever echoed', () {
      final ci = _read(codemagicPath);
      // Nothing may print the material or the passwords.
      for (final bad in const [
        r'echo "$ANDROID_KEYSTORE_BASE64',
        r'echo $ANDROID_KEYSTORE_BASE64',
        r'echo "$ANDROID_KEYSTORE_PASSWORD',
        r'echo "$ANDROID_KEY_PASSWORD',
      ]) {
        expect(ci.contains(bad), isFalse, reason: 'leaks via: $bad');
      }
    });

    test('no real keystore value is committed to CI config', () {
      final ci = _read(codemagicPath);
      // Only ${VAR} references — never an inline blob.
      expect(RegExp(r'ANDROID_KEYSTORE_BASE64\s*[:=]\s*[A-Za-z0-9+/]{40,}')
          .hasMatch(ci), isFalse);
    });
  });
}
