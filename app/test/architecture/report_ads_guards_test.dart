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
}
