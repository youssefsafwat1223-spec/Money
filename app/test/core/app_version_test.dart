import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backend/app_version.dart';

/// F-024 — the client must report a real version.
///
/// `X-App-Version` is how the catalog endpoints decide which announcements,
/// feature flags and force-update rows apply to a client. Every call site read
/// `String.fromEnvironment('APP_VERSION')` and no build defined it, so the
/// header was always `''` and version-targeted rules could never match. A
/// force-update aimed at "clients below 0.2.0" reached nobody, silently.
void main() {
  test('the version is never empty', () {
    // The original defect, stated directly.
    expect(kAppVersion, isNotEmpty,
        reason: 'an empty X-App-Version makes every version-targeted rule '
            'unmatchable, including the force-update kill switch');
  });

  test('the fallback constant matches pubspec — it cannot rot silently', () {
    // The constant exists only because the runtime alternative would need a new
    // direct dependency and an async value. That trade is only acceptable while
    // drift is impossible, which is what this asserts.
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match =
        RegExp(r'^version:\s*([0-9]+\.[0-9]+\.[0-9]+)', multiLine: true)
            .firstMatch(pubspec);
    expect(match, isNotNull, reason: 'pubspec has no parseable version');

    expect(kPubspecVersion, match!.group(1),
        reason: 'kPubspecVersion has drifted from pubspec.yaml. Bump BOTH — a '
            'stale constant reintroduces F-024 in a quieter form: the client '
            'reports a version it is not.');
  });

  test('it looks like a version the server can compare', () {
    // Server-side targeting does an ordered comparison; a non-semver string
    // would compare in ways nobody intends rather than failing loudly.
    expect(RegExp(r'^[0-9]+\.[0-9]+\.[0-9]+').hasMatch(kAppVersion), isTrue,
        reason: 'got "$kAppVersion"');
  });

  test('there is exactly one header source', () {
    expect(kAppVersionHeaders['X-App-Version'], kAppVersion);
    expect(kAppVersionHeaders.length, 1);
  });

  test('no call site re-derives the version from the environment', () {
    // The defect was six independent copies of the same expression. A fix
    // applied to one would have missed five, so the duplication itself is the
    // thing to prevent — not just its current instances.
    final lib = Directory('lib');
    final offenders = <String>[];
    for (final e in lib.listSync(recursive: true)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      if (e.path.endsWith('core/backend/app_version.dart')) continue;
      if (e.readAsStringSync().contains("fromEnvironment('APP_VERSION')")) {
        offenders.add(e.path);
      }
    }
    expect(offenders, isEmpty,
        reason: 'these read APP_VERSION directly instead of using '
            'kAppVersion/kAppVersionHeaders:\n  ${offenders.join('\n  ')}');
  });
}
