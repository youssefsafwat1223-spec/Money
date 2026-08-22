import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Architecture guards for the report-export ads layer (R4 §31). Static source
/// scans — they assert the boundaries the design forbids, and fail loudly if a
/// later change crosses one.

String _read(String path) => File(path).readAsStringSync();

List<String> _adsLayerSources() {
  final dir = Directory('lib/features/report_ads');
  return dir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .map((f) => f.readAsStringSync())
      .toList();
}

Iterable<File> _allLibDart() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'));

void main() {
  test('no rewarded-ad concepts anywhere in the ads layer', () {
    for (final src in _adsLayerSources()) {
      expect(src.contains('RewardedAd'), isFalse, reason: 'no RewardedAd');
      expect(src.contains('RewardedInterstitialAd'), isFalse,
          reason: 'no RewardedInterstitialAd');
      expect(src.contains('OnUserEarnedReward'), isFalse,
          reason: 'no OnUserEarnedReward');
      expect(src.contains('onUserEarnedReward'), isFalse);
    }
  });

  test('no rewarded-ad concepts anywhere in lib', () {
    for (final f in _allLibDart()) {
      final src = f.readAsStringSync();
      expect(src.contains('RewardedInterstitialAd'), isFalse, reason: f.path);
      expect(src.contains('OnUserEarnedReward'), isFalse, reason: f.path);
    }
  });

  test('no Qirsh-owned adConsentState (UMP is the sole authority)', () {
    for (final f in _allLibDart()) {
      expect(f.readAsStringSync().contains('adConsentState'), isFalse,
          reason: 'adConsentState found in ${f.path}');
    }
  });

  test('no report_ads_config table/symbol in the client', () {
    for (final f in _allLibDart()) {
      expect(f.readAsStringSync().contains('report_ads_config'), isFalse,
          reason: 'report_ads_config found in ${f.path}');
    }
  });

  test('Drift schema stays v31 (no v32 for R4)', () {
    final db = _read('lib/data/db/app_database.dart');
    expect(RegExp(r'_targetSchemaVersion\s*=\s*31').hasMatch(db), isTrue,
        reason: 'schema version must remain 31');
  });

  test('the ads layer never reads entitlement tables directly', () {
    const tables = [
      'user_entitlement_state',
      'entitlement_events',
      'referral_reward_progress',
      'referral_reward_grants',
    ];
    for (final src in _adsLayerSources()) {
      for (final t in tables) {
        expect(src.contains("'$t'"), isFalse, reason: 'direct read of $t');
      }
      expect(src.contains('.from('), isFalse,
          reason: 'the ads layer must not issue a direct table read');
    }
  });

  test('no production ad IDs in source — only Google test publisher units', () {
    final re = RegExp(r'ca-app-pub-[0-9]+');
    for (final f in _allLibDart()) {
      for (final m in re.allMatches(f.readAsStringSync())) {
        expect(m.group(0), contains('3940256099942544'),
            reason: 'non-test ad id ${m.group(0)} in ${f.path}');
      }
    }
  });

  test('the ads layer contains no report-generation logic', () {
    for (final src in _adsLayerSources()) {
      expect(src.contains('runReportGeneration'), isFalse);
      expect(src.contains('ReportGenerationController'), isFalse);
      expect(src.contains('report_config_sheet'), isFalse);
      expect(src.contains('report_generation'), isFalse);
    }
  });

  // ── R7 I3/A3 — AdMob release configuration plumbing ──────────────────────
  //
  // The repository and QA builds are ALLOWED to carry Google's TEST identifiers.
  // What must be impossible is a SHIPPING build resolving them implicitly, so
  // these guards pin the plumbing rather than banning the test publisher.

  test('iOS GADApplicationIdentifier is build-configured, not a literal', () {
    final plist = File('ios/Runner/Info.plist').readAsStringSync();
    final idx = plist.indexOf('GADApplicationIdentifier');
    expect(idx, greaterThan(-1), reason: 'the AdMob app id key must exist');
    final after = plist.substring(idx, idx + 200);
    expect(after, contains(r'$(ADMOB_APP_ID)'),
        reason: 'the app id must come from the build setting');
    expect(after, isNot(contains('ca-app-pub-')),
        reason: 'no hardcoded AdMob app id may ship in Info.plist');
  });

  test('iOS ADMOB_APP_ID is test-only on dev configs and injected on Release',
      () {
    final pbx = File('ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();
    // Release must defer to the injected variable...
    expect(pbx, contains(r'ADMOB_APP_ID = "$(ADMOB_APP_ID_IOS)"'),
        reason: 'Release must take the app id from the release pipeline');
    // ...and the only literal present must be Google's TEST app id.
    final literals = RegExp(r'ADMOB_APP_ID = "(ca-app-pub-[^"]+)"')
        .allMatches(pbx)
        .map((m) => m.group(1)!)
        .toSet();
    for (final v in literals) {
      expect(v, startsWith('ca-app-pub-3940256099942544'),
          reason: 'only Google TEST app ids may be committed');
    }
  });

  test('Android APPLICATION_ID is a manifest placeholder, not a literal', () {
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    final idx = manifest.indexOf('com.google.android.gms.ads.APPLICATION_ID');
    expect(idx, greaterThan(-1));
    final after = manifest.substring(idx, idx + 200);
    expect(after, contains(r'${admobAppId}'),
        reason: 'the app id must come from the Gradle placeholder');
    expect(after, isNot(contains('ca-app-pub-')),
        reason: 'no hardcoded AdMob app id may ship in the manifest');
  });

  test('Gradle resolves the release app id from env/property', () {
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();
    expect(gradle, contains('ADMOB_APP_ID_ANDROID'));
    expect(gradle, contains('manifestPlaceholders["admobAppId"]'));
  });

  test('the four canonical config names are the only ones used', () {
    final cfg =
        File('lib/features/report_ads/report_ads_build_config.dart')
            .readAsStringSync();
    for (final name in const [
      'ADMOB_APP_ID_IOS',
      'ADMOB_APP_ID_ANDROID',
      'ADMOB_INTERSTITIAL_IOS',
      'ADMOB_INTERSTITIAL_ANDROID',
    ]) {
      expect(cfg, contains("String.fromEnvironment('$name')"), reason: name);
    }
    // No alias/duplicate configuration system crept in.
    final names = RegExp(r"String\.fromEnvironment\('(ADMOB_[A-Z_]+)'\)")
        .allMatches(cfg)
        .map((m) => m.group(1)!)
        .toSet();
    expect(names.length, 4, reason: 'exactly four AdMob inputs: $names');
  });
}
