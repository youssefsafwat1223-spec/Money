import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Isolated physical-QA app instance — the guards that keep it out of a release.
///
/// ## Why this exists
///
/// Post-auth QA needs a real iPhone, a real Supabase session and real RLS. It
/// must NOT need the real app's data. On 2026-09-08 a QA sign-in against the
/// installed app wiped its local database: `AppSession.signOut` wipes outright
/// (`app_session.dart`), and admitting a different uid trips the owner gate,
/// which wipes to hand the database to the incoming owner. Both are correct
/// product behaviour and neither asks first.
///
/// The fix is a separate bundle id — iOS then gives the QA build its own
/// container, so its Drift database, SharedPreferences and keychain items are
/// physically different files from the real app's. The backend is deliberately
/// NOT isolated: QA runs against production Supabase with a real JWT.
///
/// The identity switch is driven by `QIRSH_BUNDLE_SUFFIX`, which defaults to
/// empty everywhere. Only a local, gitignored `ios/Flutter/QA.xcconfig` sets
/// it, and only Debug reads that file. These tests pin that arrangement: the
/// danger is not the QA build, it is a QA identifier reaching a shipped one.
void main() {
  final root = Directory.current.path;
  String read(String p) => File('$root/$p').readAsStringSync();

  /// Comments in these files legitimately mention the very strings the guards
  /// forbid ("does not include QA.xcconfig", "omitting keychain-access-groups").
  /// Assertions must read settings, not prose.
  String settingsOnly(String src) => src
      .replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '')
      .replaceAll(RegExp(r'^\s*//.*$', multiLine: true), '');

  final debugCfg = read('ios/Flutter/Debug.xcconfig');
  final releaseCfg = read('ios/Flutter/Release.xcconfig');
  final extDebugCfg = read('ios/Flutter/ShareExtDebug.xcconfig');
  final extReleaseCfg = read('ios/Flutter/ShareExtRelease.xcconfig');
  final pbxproj = read('ios/Runner.xcodeproj/project.pbxproj');

  group('the QA identifier cannot reach a release build', () {
    test('release xcconfigs never include the QA override', () {
      // The whole safety argument. A release build must resolve to production
      // identifiers even on this machine, where QA.xcconfig exists.
      expect(settingsOnly(releaseCfg).contains('QA.xcconfig'), isFalse,
          reason: 'Release.xcconfig must not include the QA override');
      expect(settingsOnly(extReleaseCfg).contains('QA.xcconfig'), isFalse,
          reason: 'ShareExtRelease.xcconfig must not include the QA override');
    });

    test('release xcconfigs pin the suffixes to empty', () {
      for (final cfg in [releaseCfg, extReleaseCfg]) {
        expect(RegExp(r'^QIRSH_BUNDLE_SUFFIX\s*=\s*$', multiLine: true)
            .hasMatch(cfg), isTrue);
        expect(RegExp(r'^QIRSH_ENTITLEMENTS_SUFFIX\s*=\s*$', multiLine: true)
            .hasMatch(cfg), isTrue);
      }
    });

    test('debug defaults to production before the override is included', () {
      // Order matters: the default must be assigned ABOVE the include, so a
      // machine without QA.xcconfig (CI, a fresh clone) builds the real app.
      for (final cfg in [debugCfg, extDebugCfg]) {
        final defaultAt = cfg.indexOf(RegExp(r'^QIRSH_BUNDLE_SUFFIX\s*=\s*$',
            multiLine: true));
        final includeAt = cfg.indexOf('QA.xcconfig');
        expect(defaultAt, isNonNegative, reason: 'no empty default');
        expect(includeAt, isNonNegative, reason: 'no QA include');
        expect(defaultAt < includeAt, isTrue,
            reason: 'the QA include must come after the empty default');
      }
    });

    test('the QA override file is gitignored', () {
      expect(read('../.gitignore').contains('app/ios/Flutter/QA.xcconfig'),
          isTrue,
          reason: 'QA.xcconfig must never be committed');
    });

    test('no bundle identifier is hardcoded past the suffix', () {
      // Every id must flow through the suffix, or a target silently keeps the
      // production container while the rest of the app moves.
      // RunnerTests is excluded deliberately: it is a host-app test bundle that
      // never ships and never gets its own container.
      final bare = RegExp(
              r'PRODUCT_BUNDLE_IDENTIFIER = com\.youssefsafwat\.mali(?!\.RunnerTests)')
          .allMatches(pbxproj)
          .length;
      expect(bare, 0,
          reason: 'unquoted/unsuffixed production id left in project.pbxproj');
      expect(pbxproj.contains(r'"com.youssefsafwat.mali$(QIRSH_BUNDLE_SUFFIX)"'),
          isTrue);
    });
  });

  group('the QA container is genuinely separate', () {
    final prodEnt = read('ios/Runner/Runner.entitlements');
    final qaEnt = read('ios/Runner/RunnerQA.entitlements');

    test('production entitlements keep their capabilities', () {
      // Nothing about the real app may be weakened to make QA possible.
      expect(prodEnt.contains('group.com.youssefsafwat.mali'), isTrue);
      expect(prodEnt.contains('keychain-access-groups'), isTrue);
      expect(prodEnt.contains(r'$(APS_ENVIRONMENT)'), isTrue);
      expect(prodEnt.contains('com.apple.developer.applesignin'), isTrue);
    });

    test('QA entitlements grant no shared container', () {
      // Absence IS the isolation: without the entitlement iOS refuses the QA
      // build access to the real app's App Group and keychain group.
      expect(settingsOnly(qaEnt).contains('application-groups'), isFalse);
      expect(settingsOnly(qaEnt).contains('keychain-access-groups'), isFalse);
      expect(
          settingsOnly(read(
                  'ios/ShareBankMessage/ShareBankMessageQA.entitlements'))
              .contains('application-groups'),
          isFalse);
    });
  });

  group('QA credentials never enter source', () {
    test('no QA define is read outside integration_test', () {
      final offenders = <String>[];
      for (final dir in ['lib', 'ios', 'test']) {
        final d = Directory('$root/$dir');
        if (!d.existsSync()) continue;
        for (final f in d.listSync(recursive: true).whereType<File>()) {
          if (!f.path.endsWith('.dart') && !f.path.endsWith('.swift')) continue;
          if (f.path.endsWith('qa_instance_isolation_test.dart')) continue;
          final src = f.readAsStringSync();
          if (src.contains('QA_PASSWORD') || src.contains('QA_EMAIL')) {
            offenders.add(f.path);
          }
        }
      }
      expect(offenders, isEmpty,
          reason: 'QA credentials belong to integration_test dart-defines only');
    });

    test('the harness supplies no fallback credential', () {
      // A default value would be a committed credential.
      final harness = read('integration_test/post_auth_journeys_test.dart');
      for (final k in ['QA_EMAIL', 'QA_PASSWORD', 'QA_USER_ID']) {
        expect(harness.contains("String.fromEnvironment('$k')"), isTrue);
        expect(harness.contains("fromEnvironment('$k', defaultValue"), isFalse,
            reason: '$k must have no compiled-in default');
      }
    });
  });

  test('the production owner gate still wipes', () {
    // The defect that started this was real product behaviour. QA routes around
    // it with a separate container; it must never be softened to let a test
    // pass. If this fails, check that weakening was intended.
    final session = read('lib/core/session/app_session.dart');
    expect(session.contains('await wipe();'), isTrue,
        reason: 'owner-change wipe removed — QA must not change product safety');
  });
}
