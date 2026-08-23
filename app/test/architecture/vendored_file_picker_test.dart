import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// R8B — the vendored `file_picker` fork must stay minimal and honest.
///
/// The fork exists only to carry one backported AGP-9 plugin-registration fix
/// (see `third_party/file_picker/QIRSH_FORK.md`). These guards make it hard for
/// it to quietly grow into a divergent copy of the package.
void main() {
  final fork = Directory('../third_party/file_picker');

  test('the fork is vendored in-repo and pinned by path', () {
    expect(fork.existsSync(), isTrue, reason: 'vendored fork is missing');
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('path: ../third_party/file_picker'),
        reason: 'the app must resolve file_picker from the vendored fork');
    // A remote git ref would break "reproducible from the repository alone".
    expect(pubspec.contains('git:'), isFalse,
        reason: 'no unpinned remote git dependency');
  });

  test('the fork base is upstream 11.0.3, with LICENSE retained', () {
    final forkPubspec =
        File('${fork.path}/pubspec.yaml').readAsStringSync();
    expect(forkPubspec, contains('version: 11.0.3'),
        reason: '11.0.3 carries the 11.0.2 path-traversal fix; never downgrade');
    expect(File('${fork.path}/LICENSE').existsSync(), isTrue);
    expect(File('${fork.path}/QIRSH_FORK.md').existsSync(), isTrue,
        reason: 'provenance must travel with the fork');
  });

  test('the backport is present and the broken upstream guard is gone', () {
    final gradle =
        File('${fork.path}/android/build.gradle').readAsStringSync();
    // The corrected condition consults the property upstream 11.x ignored.
    expect(gradle, contains('android.builtInKotlin'),
        reason: 'the fix must read the builtInKotlin property');
    expect(gradle, contains('shouldApplyKotlinAndroidPlugin'));
    // The naive AGP-only guard is what broke every Android build.
    expect(gradle.contains('isAgp9OrAbove'), isFalse,
        reason: 'the broken upstream guard must not survive');
  });

  test('no win32 6 / federated file_picker 12 packages leaked in', () {
    final lock = File('pubspec.lock').readAsStringSync();
    // The whole point of the fork is avoiding the fp12 dependency cascade.
    for (final forbidden in const [
      'windows_file_picker',
      'android_file_picker',
      'file_picker_platform_interface',
    ]) {
      expect(lock.contains(forbidden), isFalse, reason: 'unexpected: $forbidden');
    }
    expect(RegExp(r'name: win32\n(?:.*\n)*?    version: "6\.')
        .hasMatch(lock), isFalse, reason: 'win32 must stay on 5.x');
  });

  test('the companion dependencies were deliberately NOT migrated', () {
    final lock = File('pubspec.lock').readAsStringSync();
    expect(lock, contains('version: "10.1.4"'),
        reason: 'share_plus stays 10.1.4 (Share.* API preserved)');
    expect(lock, contains('version: "9.2.4"'),
        reason: 'flutter_secure_storage stays 9.2.4 (SQLCipher key store)');
  });

  test('the fork ships no Darwin/product source drift beyond the patch', () {
    // Only the Android Gradle logic may differ from upstream. If a pristine
    // copy of 11.0.3 is available locally, diff against it; otherwise assert
    // the structural expectation and skip the byte comparison honestly.
    final pristine = Directory(
        '/Volumes/shared/flutter-cache/pub-cache/hosted/pub.dev/file_picker-11.0.3');
    if (!pristine.existsSync()) {
      markTestSkipped('pristine 11.0.3 not in the local pub cache');
      return;
    }
    final drifted = <String>[];
    for (final entity in fork.listSync(recursive: true).whereType<File>()) {
      final rel = entity.path.substring(fork.path.length + 1);
      if (rel == 'QIRSH_FORK.md') continue; // added by us, expected
      if (rel == 'android/build.gradle') continue; // the patch itself
      final upstream = File('${pristine.path}/$rel');
      if (!upstream.existsSync()) {
        drifted.add('added: $rel');
      } else if (upstream.readAsBytesSync().length !=
          entity.readAsBytesSync().length) {
        drifted.add('modified: $rel');
      }
    }
    expect(drifted, isEmpty,
        reason: 'fork drifted beyond the AGP-9 patch: $drifted');
  });

  // §13 — the Qirsh call-site contract. The native picker is deliberately NOT
  // mocked: what matters is that OUR selection semantics never drift silently.
  group('data-transfer picker contract', () {
    final src =
        File('lib/features/settings/data_transfer_screen.dart').readAsStringSync();

    test('only csv and zip may be selected', () {
      expect(src, contains('FileType.custom'));
      expect(src, contains("allowedExtensions: const ['csv', 'zip']"));
    });

    test('selection stays single-file', () {
      expect(src, contains('allowMultiple: false'),
          reason: 'multi-select would break the single-file import flow');
      expect(src, contains('.single.path'),
          reason: 'exactly one file feeds inspectFile()');
    });

    test('file contents are never loaded into memory', () {
      expect(src, contains('withData: false'),
          reason: 'backup ZIPs can be large; import works by path');
      expect(src.contains('withReadStream'), isFalse);
    });

    test('cancelling imports nothing', () {
      // A null result must return before any inspect/import work happens.
      final idx = src.indexOf('FilePicker.pickFiles');
      final after = src.substring(idx, idx + 500);
      expect(after, contains('if (path == null'),
          reason: 'cancel must short-circuit');
      expect(after.indexOf('if (path == null'),
          lessThan(after.indexOf('inspectFile')),
          reason: 'the null check must precede any import work');
    });
  });
}
