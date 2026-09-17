import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// UNSHIPPED SURFACES — the owner's V1 classification, enforced.
///
/// Two screens exist in the tree and ship in the binary but are deliberately
/// unreachable in V1:
///
///  * `BackupScreen` — **KEEP DISABLED — V1 RELEASE REASON.** It is the only
///    place cloud backup can be turned on. Reaching it would expand V1 scope
///    and introduce a reviewer-visible cloud feature at release closure, right
///    after the consent and discovery behaviour behind it was hardened. Local
///    export/import remains available and tested.
///  * `FoundationHomeScreen` — legacy, zero reachable references, not
///    resurrected for V1.
///
/// Neither is deleted: removal is not required for release safety, and the
/// implementations are the starting point for whenever the owner does ship
/// them.
///
/// This file is what keeps "unreachable" true. A route, a button or an import
/// added later would make the classification silently false, and nothing else
/// in the suite would notice — every other test asks whether code WORKS, and
/// the property here is that it is not reachable at all.
void main() {
  List<String> dartFiles() => Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .map((f) => f.path)
      .where((p) => p.endsWith('.dart'))
      .toList();

  /// Every file that names [symbol], excluding the file that declares it.
  List<String> referencesTo(String symbol, String declaringFile) {
    final hits = <String>[];
    for (final path in dartFiles()) {
      if (path == declaringFile) continue;
      // The generated localization files mention nothing of interest and are
      // large; skipping them keeps the failure message readable.
      if (path.startsWith('lib/l10n/')) continue;
      if (File(path).readAsStringSync().contains(symbol)) hits.add(path);
    }
    return hits;
  }

  test('BackupScreen has no shipping entry point', () {
    final refs = referencesTo(
        'BackupScreen', 'lib/features/backup/backup_screen.dart');
    expect(refs, isEmpty,
        reason: 'BackupScreen is classified KEEP DISABLED for V1. Something '
            'now references it: ${refs.join(", ")}. If this is intentional, '
            'the classification in V1_FEATURE_ACTIVATION_MATRIX.md has to '
            'change first — cloud backup is the only feature it exposes.');
  });

  test('FoundationHomeScreen has no shipping entry point', () {
    final refs = referencesTo('FoundationHomeScreen',
        'lib/features/foundation/foundation_home_screen.dart');
    expect(refs, isEmpty,
        reason: 'FoundationHomeScreen is legacy and unshipped for V1. '
            'Referenced by: ${refs.join(", ")}');
  });

  test('/backup stays a redirect and builds nothing', () {
    final router = File('lib/core/router/app_router.dart').readAsStringSync();
    final route = router.substring(
      router.indexOf("path: '/backup',"),
      router.indexOf("path: '/backup/restore',"),
    );
    expect(route, contains("redirect: (context, state) => '/data-transfer'"),
        reason: 'the /backup alias no longer redirects');
    expect(route, isNot(contains('builder:')),
        reason: '/backup now builds a screen — it is an alias for old deep '
            'links, not a destination');
  });

  test('nothing in the app navigates to /backup', () {
    // The alias exists so an old deep link does not 404. A LINK to it from
    // inside the app would be a dead control: it would take the user somewhere
    // they did not ask to go.
    final offenders = <String>[];
    for (final path in dartFiles()) {
      if (path == 'lib/core/router/app_router.dart') continue;
      final source = File(path).readAsStringSync();
      for (final form in ["'/backup'", 'goNamed(\'backup\')',
        'pushNamed(\'backup\')']) {
        if (source.contains(form)) offenders.add('$path ($form)');
      }
    }
    expect(offenders, isEmpty,
        reason: 'dead navigation to the disabled backup screen: '
            '${offenders.join(", ")}');
  });

  test('neither surface is counted in the V1 route denominator', () {
    // The bilingual walk's route list IS the denominator every localization
    // and direction figure is reported against ("8 of 19"). An unreachable
    // surface in that list would inflate the denominator and, worse, be
    // reported as a shipping screen that passed.
    final walk =
        File('integration_test/bilingual_walk_test.dart').readAsStringSync();
    final routes = walk.substring(
      walk.indexOf('const _routes = <String>['),
      walk.indexOf('];', walk.indexOf('const _routes = <String>[')),
    );
    expect(routes, isNot(contains("'/backup'")),
        reason: '/backup redirects to /data-transfer, so walking it measures '
            'a different screen and counts a route that was never visited');
    expect(routes, isNot(contains('/design')));
    expect(routes, isNot(contains('foundation')));
    // And the one that IS shipping must still be there.
    expect(routes, contains("'/backup/restore'"),
        reason: 'the live restore screen dropped out of the walk');
  });

  test('cloud backup stays consent-gated even though it is unreachable', () {
    // Requirement 2 of the classification. Unreachable is not a security
    // control: the screen is one route away from returning, and whoever adds
    // that route will not re-derive the consent argument.
    final screen =
        File('lib/features/backup/backup_screen.dart').readAsStringSync();
    expect(screen, isNot(contains('backupServiceProvider).enable(')),
        reason: 'the disabled screen bypasses the consent gate again');
    expect(screen, contains('remoteBackupControllerProvider.notifier'));

    final probe = File('lib/features/settings/data_transfer_screen.dart')
        .readAsStringSync();
    expect(probe, contains('EgressClass.backup'),
        reason: 'the live backup-existence probe lost its consent gate');
  });
}
