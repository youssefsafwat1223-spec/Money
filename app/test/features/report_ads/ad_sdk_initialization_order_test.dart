import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/features/report_ads/report_ads_build_config.dart';
import 'package:money_companion/features/report_ads/report_ads_debug_config.dart';

/// Cross-model audit **H-7** — Google Mobile Ads initialization vs. UMP consent
/// authority.
///
/// The reported concern was that the SDK performs prohibited measurement /
/// network initialization at PROCESS START, upstream of every Dart gate, and
/// that the fix was to add `DELAY_APP_MEASUREMENT_INIT` (Android) /
/// `GADDelayAppMeasurementInit` (iOS).
///
/// That premise did not survive verification against the SDKs this app actually
/// ships — see `docs/FINAL_CROSS_MODEL_AUDIT_RECONCILIATION.md` (H-7). Neither
/// key exists in google_mobile_ads 9.0.0's bundled SDKs, and the Android
/// process-start provider performs no initialization at all. What these guards
/// therefore protect is the property that genuinely matters and is genuinely
/// under our control:
///
///   UMP consent-info update → required form → canRequestAds
///     → MobileAds.initialize() → preload → presentation
///
/// Because the evidence is VERSION-SPECIFIC, the version pins are guarded too:
/// an SDK bump invalidates the analysis and must re-run it.
String _read(String path) => File(path).readAsStringSync();

void main() {
  group('H-7 — the SDK version this analysis was verified against', () {
    test('google_mobile_ads stays pinned to exactly 9.0.0', () {
      final pubspec = _read('pubspec.yaml');
      expect(pubspec, contains('google_mobile_ads: 9.0.0'),
          reason: 'the H-7 native findings (no measurement auto-init, SDK app-id '
              'regex, absent delay-init keys) were verified against the SDKs '
              'bundled with 9.0.0 EXACTLY. A bump invalidates them.');
      expect(pubspec.contains('google_mobile_ads: ^9'), isFalse,
          reason: 'a caret range would silently move the native SDK');
    });
  });

  group('H-7 — Dart never initializes the SDK before UMP', () {
    final shell = _read('lib/features/app/app_shell.dart');
    final orchestration = shell.substring(
      shell.indexOf('Future<void> _orchestrateReportAdsConsent()'),
    );
    final body = orchestration.substring(0, orchestration.indexOf('\n  }'));

    test('there is exactly ONE MobileAds.initialize call site', () {
      var sites = 0;
      for (final file in Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))) {
        sites += RegExp(r'MobileAds\.instance\.initialize')
            .allMatches(_read(file.path))
            .length;
      }
      expect(sites, 1,
          reason: 'a second initialize call site would be a second ordering '
              'contract to keep correct');
    });

    test('the only initialize is inside the gateway, behind full config', () {
      final gateway =
          _read('lib/features/report_ads/report_export_ad_gateway.dart');
      final configAt = gateway.indexOf('isConfiguredFor');
      final initAt = gateway.indexOf('MobileAds.instance.initialize');
      expect(configAt, greaterThan(-1));
      expect(initAt, greaterThan(-1));
      // preload() checks configuration before it can reach _ensureMobileAds.
      final preloadAt = gateway.indexOf('Future<void> preload()');
      expect(preloadAt, lessThan(gateway.indexOf('isConfiguredFor', preloadAt)),
          reason: 'preload must verify configuration before initializing');
    });

    test('UMP is gathered BEFORE any preload can run', () {
      final gatherAt = body.indexOf('ensureGathered()');
      final preloadAt = body.indexOf('maybePreload()');
      expect(gatherAt, greaterThan(-1), reason: 'UMP must be gathered');
      expect(preloadAt, greaterThan(-1));
      expect(gatherAt, lessThan(preloadAt),
          reason: 'required order: consent-info update → form → canRequestAds '
              '→ initialize → preload');
    });

    test('ads-off in release returns before UMP and before any preload', () {
      final guardAt = body.indexOf('if (kReleaseMode && !adsMayServe) return;');
      expect(guardAt, greaterThan(-1),
          reason: 'a disabled product feature must not initialize the ad SDK '
              'or show consent UI');
      expect(guardAt, lessThan(body.indexOf('ensureGathered()')));
      expect(guardAt, lessThan(body.indexOf('maybePreload()')));
    });

    test('the privacy-options provider refreshes after gathering (R4 §4)', () {
      final gatherAt = body.indexOf('ensureGathered()');
      final refreshAt = body.indexOf('adPrivacyOptionsRequiredProvider');
      expect(refreshAt, greaterThan(gatherAt),
          reason: 'the Settings entry must reflect the freshly-known UMP state');
    });

    test('consent/preload failure is fail-open (export still proceeds)', () {
      expect(body, contains('catch (_)'),
          reason: 'a UMP or preload failure must never break the app');
    });
  });

  group('H-7 — the preload gate consults UMP, not a private consent flag', () {
    final coordinator =
        _read('lib/features/report_ads/report_export_coordinator.dart');

    test('maybePreload requires canRequestAds', () {
      final maybe = coordinator.substring(
        coordinator.indexOf('Future<void> maybePreload()'),
      );
      expect(maybe, contains('canRequestAds()'));
      final consentAt = maybe.indexOf('canRequestAds()');
      final preloadAt = maybe.indexOf('_gateway.preload()');
      expect(consentAt, lessThan(preloadAt),
          reason: 'no ad may be requested before UMP permits ad requests');
    });

    test('entitlement gates the preload (active and unknown both skip)', () {
      final maybe = coordinator.substring(
        coordinator.indexOf('Future<void> maybePreload()'),
      );
      expect(maybe, contains('verifiedInactive'),
          reason: 'only VERIFIED_INACTIVE is ad-eligible; ACTIVE and '
              'UNKNOWN_OR_STALE must not load an ad');
    });

    test('UMP remains the SOLE consent authority', () {
      // No parallel consent state, no analytics-consent substitution, no ATT.
      for (final file in Directory('lib/features/report_ads')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))) {
        final src = _read(file.path);
        for (final forbidden in const [
          'adConsentState',
          'AppTrackingTransparency',
          'requestTrackingAuthorization',
        ]) {
          expect(src.contains(forbidden), isFalse,
              reason: '${file.path}: UMP must remain the only ad-consent '
                  'authority — found "$forbidden"');
        }
      }
    });
  });

  group('H-7 — native configuration, both platforms', () {
    test('Android declares the AdMob application id via a build placeholder',
        () {
      final manifest = _read('android/app/src/main/AndroidManifest.xml');
      expect(manifest, contains('com.google.android.gms.ads.APPLICATION_ID'));
      expect(manifest, contains(r'${admobAppId}'),
          reason: 'no literal id may be committed');
    });

    test('Android validation matches the SDK regex EXACTLY', () {
      // Verified by disassembly: play-services-ads-api:25.3.0
      // zzev#attachInfo applies ^ca-app-pub-[0-9]{16}~[0-9]{10}$ at process
      // start and throws IllegalStateException on a mismatch. A looser gate
      // would pass a value that still crashes the app at launch.
      final gradle = _read('android/app/build.gradle.kts');
      expect(gradle, contains(r'^ca-app-pub-[0-9]{16}~[0-9]{10}$'));
    });

    test('the Dart shape check matches the native SDK shape', () {
      expect(ReportAdsBuildConfig.isValidAppId(
          'ca-app-pub-3940256099942544~1458002511'), isTrue);
      // Too few digits — accepted by the old looser regex, rejected by the SDK.
      expect(ReportAdsBuildConfig.isValidAppId('ca-app-pub-1234567890~123456'),
          isFalse,
          reason: 'the Dart gate must not be looser than the SDK, or a build '
              'passes here and crashes at launch');
      expect(ReportAdsBuildConfig.isValidUnitId(
          'ca-app-pub-3940256099942544/1033173712'), isTrue);
      // App id in a unit slot (the classic mix-up).
      expect(ReportAdsBuildConfig.isValidUnitId(
          'ca-app-pub-3940256099942544~1458002511'), isFalse);
    });

    test('iOS declares the application id via a build setting', () {
      final plist = _read('ios/Runner/Info.plist');
      expect(plist, contains('GADApplicationIdentifier'));
      expect(plist, contains(r'$(ADMOB_APP_ID)'),
          reason: 'no literal id may be committed');
    });

    test('iOS does not claim an unsupported delay-init key', () {
      // GADDelayAppMeasurementInit is ABSENT from the GMA binary bundled with
      // google_mobile_ads 9.0.0 (checked against the framework's string table,
      // where GADApplicationIdentifier IS present). Adding it would be
      // decoration that implies a protection the SDK does not provide.
      final plist = _read('ios/Runner/Info.plist');
      expect(plist.contains('GADDelayAppMeasurementInit'), isFalse,
          reason: 'unsupported in this SDK version — do not add a key that '
              'reads as a mitigation but does nothing');
    });
  });

  group('H-7 — QA/debug paths stay release-inert', () {
    test('every debug hook is false in a release build', () {
      // Pure function, so both branches are exercised without a release build.
      expect(
        ReportAdsDebugConfig.computeDebugOnly(
            isReleaseBuild: true, defineSet: true),
        isFalse,
        reason: 'a release build must never inherit debug ad/UMP behaviour',
      );
      expect(
        ReportAdsDebugConfig.computeDebugOnly(
            isReleaseBuild: false, defineSet: true),
        isTrue,
      );
      expect(
        ReportAdsDebugConfig.computeDebugOnly(
            isReleaseBuild: false, defineSet: false),
        isFalse,
      );
    });

    test('all three QA hooks route through the release-inert helper', () {
      final debug = _read('lib/features/report_ads/report_ads_debug_config.dart');
      for (final define in const [
        'UMP_DEBUG_FORCE_EEA',
        'UMP_DEBUG_TEST_DEVICE',
        'REPORT_ADS_TEST_OVERRIDE',
      ]) {
        expect(debug, contains(define));
      }
      // Every exposed getter must be computeDebugOnly-gated.
      final getters = RegExp(r'static bool get \w+').allMatches(debug).length;
      final gated = RegExp(r'computeDebugOnly\(').allMatches(debug).length;
      expect(gated, greaterThanOrEqualTo(getters),
          reason: 'a QA hook that bypasses computeDebugOnly could leak into '
              'release');
    });

    test('debug builds still use Google TEST identifiers only', () {
      expect(ReportAdsBuildConfig.testAppIdIos,
          startsWith(ReportAdsBuildConfig.googleTestPublisher));
      expect(ReportAdsBuildConfig.testInterstitialAndroid,
          startsWith(ReportAdsBuildConfig.googleTestPublisher));
    });
  });
}
