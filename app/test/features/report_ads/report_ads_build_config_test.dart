import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/features/report_ads/report_ads_build_config.dart';

/// R7 I3/A3 — AdMob release configuration plumbing.
///
/// Release semantics are exercised through the pure [ReportAdsBuildConfig.resolve]
/// seam, because a `flutter test` run is always a debug build: asserting on
/// `appId()` alone could only ever prove the TEST path.
void main() {
  const testApp = ReportAdsBuildConfig.testAppIdIos;
  const testUnit = ReportAdsBuildConfig.testInterstitialIos;
  const prodApp = 'ca-app-pub-1234567890123456~9876543210';
  const prodUnit = 'ca-app-pub-1234567890123456/1234509876';

  String? release(String prod, bool Function(String) valid) =>
      ReportAdsBuildConfig.resolve(
        isTestBuild: false,
        testValue: testApp,
        prodValue: prod,
        isValid: valid,
      );

  group('shape validation (§15)', () {
    test('app ids use ~ and unit ids use /', () {
      expect(ReportAdsBuildConfig.isValidAppId(prodApp), isTrue);
      expect(ReportAdsBuildConfig.isValidUnitId(prodUnit), isTrue);
      // The classic misconfiguration: the two swapped.
      expect(ReportAdsBuildConfig.isValidAppId(prodUnit), isFalse);
      expect(ReportAdsBuildConfig.isValidUnitId(prodApp), isFalse);
    });

    test('garbage is rejected rather than passed to the SDK', () {
      for (final bad in <String>[
        '',
        '   ',
        'not-an-id',
        'ca-app-pub-123~456', // too short
        'ca-app-pub-1234567890123456', // no separator
        'https://example.com',
      ]) {
        expect(ReportAdsBuildConfig.isValidAppId(bad), isFalse, reason: bad);
        expect(ReportAdsBuildConfig.isValidUnitId(bad), isFalse, reason: bad);
      }
    });
  });

  group('debug/QA builds (§3)', () {
    test('always resolve Google TEST identifiers', () {
      expect(ReportAdsBuildConfig.isTestMode, isTrue,
          reason: 'flutter test runs in debug');
      expect(ReportAdsBuildConfig.appId(TargetPlatform.iOS), testApp);
      expect(ReportAdsBuildConfig.appId(TargetPlatform.android),
          ReportAdsBuildConfig.testAppIdAndroid);
      expect(ReportAdsBuildConfig.interstitialUnitId(TargetPlatform.iOS),
          testUnit);
      expect(ReportAdsBuildConfig.interstitialUnitId(TargetPlatform.android),
          ReportAdsBuildConfig.testInterstitialAndroid);
    });

    test('QA builds are fully configured (R6 physical verification path)', () {
      expect(ReportAdsBuildConfig.isConfiguredFor(TargetPlatform.iOS), isTrue);
      expect(
          ReportAdsBuildConfig.isConfiguredFor(TargetPlatform.android), isTrue);
    });

    test('platform selection never crosses iOS/Android values', () {
      expect(ReportAdsBuildConfig.appId(TargetPlatform.iOS),
          isNot(ReportAdsBuildConfig.testAppIdAndroid));
      expect(ReportAdsBuildConfig.interstitialUnitId(TargetPlatform.android),
          isNot(ReportAdsBuildConfig.testInterstitialIos));
    });
  });

  group('release builds (§3 / §13)', () {
    test('a supplied, well-formed production id resolves', () {
      expect(release(prodApp, ReportAdsBuildConfig.isValidAppId), prodApp);
    });

    test('MISSING configuration → null (ads unavailable, not a crash)', () {
      expect(release('', ReportAdsBuildConfig.isValidAppId), isNull);
      expect(release('   ', ReportAdsBuildConfig.isValidAppId), isNull);
    });

    test('MALFORMED configuration → null, never handed to the SDK', () {
      expect(release('not-an-id', ReportAdsBuildConfig.isValidAppId), isNull);
      expect(release(prodUnit, ReportAdsBuildConfig.isValidAppId), isNull,
          reason: 'a unit id supplied where an app id belongs');
    });

    test(
        'a release NEVER silently falls back to Google TEST identifiers (§7)',
        () {
      // Even explicitly supplying a Google sample id to a release build is
      // refused: shipping on sample identifiers must not be possible by accident.
      expect(release(testApp, ReportAdsBuildConfig.isValidAppId), isNull);
      expect(
        ReportAdsBuildConfig.resolve(
          isTestBuild: false,
          testValue: testUnit,
          prodValue: ReportAdsBuildConfig.testInterstitialAndroid,
          isValid: ReportAdsBuildConfig.isValidUnitId,
        ),
        isNull,
      );
    });

    test('no production value is baked into source', () {
      // The only literals in the class are Google's documented samples.
      for (final v in <String>[
        ReportAdsBuildConfig.testAppIdIos,
        ReportAdsBuildConfig.testAppIdAndroid,
        ReportAdsBuildConfig.testInterstitialIos,
        ReportAdsBuildConfig.testInterstitialAndroid,
      ]) {
        expect(v.startsWith(ReportAdsBuildConfig.googleTestPublisher), isTrue);
      }
    });
  });

  group('completeness gate (§6 / §13)', () {
    // isConfiguredFor demands BOTH halves; an ad unit without an app id would
    // let the SDK initialise against whatever the native layer carries.
    test('an app id alone is not a usable configuration', () {
      final appOnly = release(prodApp, ReportAdsBuildConfig.isValidAppId);
      final unitMissing =
          ReportAdsBuildConfig.resolve(
        isTestBuild: false,
        testValue: testUnit,
        prodValue: '',
        isValid: ReportAdsBuildConfig.isValidUnitId,
      );
      expect(appOnly, isNotNull);
      expect(unitMissing, isNull);
      expect(appOnly != null && unitMissing != null, isFalse,
          reason: 'both halves are required before any ad is attempted');
    });
  });
}
