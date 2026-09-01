import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Architecture guards for the report-export ads layer (R4 §31). Static source
/// scans — they assert the boundaries the design forbids, and fail loudly if a
/// later change crosses one.

String _read(String path) => File(path).readAsStringSync();

/// BOTH ads directories. `features/ads` holds the shared layer (build config,
/// SDK init, placements, banners); `features/report_ads` holds what is specific
/// to the report-export interstitial. Every invariant below applies to both — a
/// guard that only covered the old directory would have silently stopped
/// guarding the moment the banner work moved the config out of it.
const _adsLayerDirs = ['lib/features/ads', 'lib/features/report_ads'];

List<File> _adsLayerFiles() => [
      for (final d in _adsLayerDirs)
        ...Directory(d)
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart')),
    ];

List<String> _adsLayerSources() =>
    _adsLayerFiles().map((f) => f.readAsStringSync()).toList();

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

  test('R4 contributes no schema change', () {
    // The guard's intent is that the ADS track introduces no migration — it
    // was originally written as a global pin to v31, which over-reached once
    // another track legitimately bumped the version.
    //
    // v34 is owned by COUPONS Phase 1 (the merchant catalog cache); v32/v33 by
    // PHASE 8/9A. Each is an approved and
    // separately gated change. So the version pin now tracks the current
    // approved value, and the R4-specific claim is asserted directly below,
    // where it belongs.
    final db = _read('lib/data/db/app_database.dart');
    expect(RegExp(r'_targetSchemaVersion\s*=\s*35').hasMatch(db), isTrue,
        reason: 'unexpected schema version — a bump must be an approved, '
            'separately gated change');
  });

  test('the ads layer contains no schema or migration code', () {
    // This is what "no v32 for R4" actually meant, and it is stronger than a
    // global version pin: it fails if the ads track ever adds a migration,
    // whatever the version number happens to be.
    for (final src in _adsLayerSources()) {
      for (final forbidden in const [
        'CREATE TABLE',
        'ALTER TABLE',
        '_targetSchemaVersion',
        'MigrationStrategy',
        'customStatement',
      ]) {
        expect(src.contains(forbidden), isFalse,
            reason: 'the ads layer must not carry schema work ($forbidden)');
      }
    }
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
    const configPath = 'lib/features/ads/admob_build_config.dart';
    final cfg = File(configPath).readAsStringSync();
    for (final name in const [
      'ADMOB_APP_ID_IOS',
      'ADMOB_APP_ID_ANDROID',
      'ADMOB_INTERSTITIAL_IOS',
      'ADMOB_INTERSTITIAL_ANDROID',
      'ADMOB_BANNER_IOS',
      'ADMOB_BANNER_ANDROID',
    ]) {
      expect(cfg, contains("String.fromEnvironment('$name')"), reason: name);
    }
    // No alias/duplicate configuration system crept in. Six, not four: the
    // banner work added two inputs, and editing THIS NUMBER is the deliberate
    // act the guard exists to force. Adding an AdMob input must never be
    // possible without touching this line.
    final names = RegExp(r"String\.fromEnvironment\('(ADMOB_[A-Z_]+)'\)")
        .allMatches(cfg)
        .map((m) => m.group(1)!)
        .toSet();
    expect(names.length, 6, reason: 'exactly six AdMob inputs: $names');

    // ...and they live in exactly ONE file. A second config file would give
    // each of them a weaker, per-file invariant instead of one strong one.
    for (final f in _allLibDart()) {
      if (f.path.replaceAll(r'\\', '/').endsWith(configPath)) continue;
      expect(f.readAsStringSync().contains("fromEnvironment('ADMOB_"), isFalse,
          reason: 'AdMob build input outside $configPath: ${f.path}');
    }
  });

  // ── BANNER ADS ───────────────────────────────────────────────────────────

  test('Google Mobile Ads types never escape the ads layer', () {
    final adsPaths =
        _adsLayerFiles().map((f) => f.path.replaceAll(r'\\', '/')).toSet();
    for (final f in _allLibDart()) {
      if (adsPaths.contains(f.path.replaceAll(r'\\', '/'))) continue;
      final src = f.readAsStringSync();
      expect(src.contains('package:google_mobile_ads/'), isFalse,
          reason: 'the SDK must stay behind the ads layer: ${f.path}');
      for (final symbol in const [
        'BannerAd(',
        'AdWidget(',
        'AdSize.',
        'InterstitialAd.',
        'MobileAds.instance',
      ]) {
        expect(src.contains(symbol), isFalse,
            reason: '$symbol leaked into ${f.path}');
      }
    }
  });

  test('the ads layer depends on nothing financial', () {
    // Ads may render UI. Ads may not become part of financial state, and they
    // must not be able to READ it either — no targeting can be built out of a
    // user's bank messages if the types are unreachable from here.
    for (final f in _adsLayerFiles()) {
      final src = f.readAsStringSync();
      for (final forbidden in const [
        "import '../../domain/",
        "import '../../engine/",
        "import '../../data/repositories/",
        'package:money_companion/domain/',
        'package:money_companion/engine/',
        'package:money_companion/data/repositories/',
      ]) {
        expect(src.contains(forbidden), isFalse,
            reason: 'financial dependency in ${f.path}: $forbidden');
      }
    }
  });

  test('QirshAdBanner appears ONLY at approved placement call sites', () {
    // A positive allowlist, not a list of forbidden filenames. Enumerating the
    // screens an ad must never reach is unbounded and silently stops covering
    // any screen added later; enumerating the ones it MAY reach is finite and
    // fails closed — a new placement cannot ship without editing this list.
    const approved = {
      'lib/features/transactions/transactions_screen.dart',
    };
    final found = <String>{};
    for (final f in _allLibDart()) {
      final path = f.path.replaceAll(r'\\', '/');
      if (path.startsWith('lib/features/ads/')) continue;
      if (f.readAsStringSync().contains('QirshAdBanner')) found.add(path);
    }
    expect(found, approved,
        reason: 'banner call sites changed — approve the new placement here, '
            'and check it against the NEVER list in docs/BANNER_ADS_SYSTEM.md');
  });

  test('the banner flag keys exist in the flag defaults', () {
    // `getBool` consults the remote cache first and falls back to `_defaults`.
    // A key in neither is false by ACCIDENT — indistinguishable from "off"
    // right up until someone flips it remotely and nothing happens.
    final defaults =
        File('lib/data/catalog/feature_flag_service.dart').readAsStringSync();
    for (final key in const [
      'enable_banner_ads',
      'enable_banner_transactions_list',
    ]) {
      expect(defaults, contains("'$key': false"),
          reason: '$key must be seeded OFF in _defaults');
    }
  });

  test('no banner placement has a raw ad unit id', () {
    // Placements name an enum; the enum maps to a unit in ONE function. A raw
    // id in a feature file cannot be disabled independently or reported on.
    final placement =
        File('lib/features/ads/ad_placement.dart').readAsStringSync();
    expect(placement.contains('ca-app-pub-'), isFalse);
  });
}
