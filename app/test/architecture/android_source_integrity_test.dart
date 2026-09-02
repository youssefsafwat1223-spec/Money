import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Android source integrity — the cheap half of "does the Android app build".
///
/// ## Why this exists
///
/// On 2026-09-02 the Android app was found to be **completely unbuildable**, and
/// had been since commit `564f1327`. `OfferIntentStore.kt` and
/// `SharedContentRouter.kt` were added declaring `package
/// com.example.money_companion` — matching the DIRECTORY they sit in — while
/// every other Kotlin file in the app, and the `applicationId`, use
/// `com.youssefsafwat.mali`. `MainActivity` could not resolve either class.
///
/// The whole canonical CI suite — 12 mandatory gates, 3537 Flutter tests, Deno,
/// Node, admin, migration lint, architecture guards — passed the entire time.
/// **Nothing in this repository compiles the Android app.** It was caught only
/// by physically building for a device.
///
/// A full `flutter build apk` takes ~38 minutes and cannot sit in the inner
/// loop. These checks are static, run in milliseconds, and catch the specific
/// failure that actually happened. They are NOT a substitute for compiling —
/// see `docs/project/RELEASE_BLOCKERS.md` for the real gap.

String _pkgOf(File f) {
  for (final line in f.readAsLinesSync()) {
    final t = line.trim();
    if (t.startsWith('package ')) return t.substring(8).trim().replaceAll(';', '');
    // Only the header matters; stop at the first real declaration.
    if (t.startsWith('import ') || t.startsWith('class ')) break;
  }
  return '';
}

void main() {
  final kotlinRoot = Directory('android/app/src/main/kotlin');
  final sources = kotlinRoot
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.kt'))
      .toList();

  test('there are Kotlin sources to check (the guard is not vacuous)', () {
    expect(sources, isNotEmpty);
  });

  test('every Kotlin file declares the SAME package', () {
    // The failure mode was one package per convention and another per
    // directory, coexisting silently. Two packages in one source set is the
    // signal, whatever the names are.
    final byPackage = <String, List<String>>{};
    for (final f in sources) {
      byPackage.putIfAbsent(_pkgOf(f), () => []).add(f.uri.pathSegments.last);
    }
    expect(byPackage.keys.length, 1,
        reason: 'Kotlin sources are split across packages, so classes in one '
            'cannot see the other without an import that nobody wrote:\n'
            '${byPackage.entries.map((e) => '  ${e.key}: ${e.value}').join('\n')}');
  });

  test('the Kotlin package matches the applicationId', () {
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();
    final appId = RegExp(r'applicationId\s*=\s*"([^"]+)"').firstMatch(gradle);
    expect(appId, isNotNull, reason: 'applicationId must be declared');
    for (final f in sources) {
      expect(_pkgOf(f), appId!.group(1),
          reason: '${f.path} declares a package that is not the applicationId');
    }
  });

  test('MainActivity can resolve every class it names from the same package',
      () {
    // Cheap approximation of "it compiles": a bare type reference resolves only
    // if the class is in the same package or explicitly imported.
    final main =
        File('android/app/src/main/kotlin/com/youssefsafwat/mali/MainActivity.kt')
                .existsSync()
            ? File(
                'android/app/src/main/kotlin/com/youssefsafwat/mali/MainActivity.kt')
            : sources.firstWhere((f) => f.path.endsWith('MainActivity.kt'));
    final src = main.readAsStringSync();
    final mainPkg = _pkgOf(main);

    final siblings = <String, String>{
      for (final f in sources)
        f.uri.pathSegments.last.replaceAll('.kt', ''): _pkgOf(f),
    };

    for (final entry in siblings.entries) {
      final name = entry.key;
      if (name == 'MainActivity') continue;
      // Only assert for classes MainActivity actually references.
      if (!RegExp('\\b$name\\b').hasMatch(src)) continue;
      final imported = src.contains('import ${entry.value}.$name');
      expect(entry.value == mainPkg || imported, isTrue,
          reason: 'MainActivity references $name, which lives in '
              '"${entry.value}" while MainActivity is in "$mainPkg", and there '
              'is no import. This is exactly the break that shipped in 564f1327 '
              'and survived every gate until someone built for a device.');
    }
  });

  test('the manifest component names resolve to the declared package', () {
    // `android:name=".Foo"` is relative to the package attribute / applicationId.
    // A component that does not exist there is an install-time or runtime
    // ClassNotFoundException, not a compile error, so nothing else catches it.
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    final declared = RegExp(r'android:name="\.(\w+)"')
        .allMatches(manifest)
        .map((m) => m.group(1)!)
        .toSet();
    final classNames =
        sources.map((f) => f.uri.pathSegments.last.replaceAll('.kt', '')).toSet();
    for (final component in declared) {
      expect(classNames, contains(component),
          reason: 'AndroidManifest declares ".$component" but no Kotlin source '
              'defines it — that is a ClassNotFoundException at runtime');
    }
  });
}
