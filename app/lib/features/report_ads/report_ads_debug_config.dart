import 'package:flutter/foundation.dart';

/// Debug/test-only UMP configuration for physical R6 verification (R4 §11 test
/// hook). It exists ONLY so a human tester can exercise the consent form,
/// privacy-options-required state, and `canRequestAds` transitions on a real
/// device WITHOUT flipping any staging feature flag.
///
/// Release safety is STRUCTURAL, not incidental: every value is ANDed with
/// `!kReleaseMode`, so a release build can never be forced into EEA geography or
/// register a test device no matter what dart-defines are passed. No physical
/// device identifier is ever hardcoded or committed — the id, if any, arrives
/// exclusively through `--dart-define=UMP_DEBUG_TEST_DEVICE=<hashed-id>`.
class ReportAdsDebugConfig {
  ReportAdsDebugConfig._();

  // Opt-in dart-defines. Absent by default → the whole mechanism is inert.
  static const bool _forceEeaDefine =
      bool.fromEnvironment('UMP_DEBUG_FORCE_EEA');
  static const String _testDeviceDefine =
      String.fromEnvironment('UMP_DEBUG_TEST_DEVICE');
  static const bool _reportAdsOverrideDefine =
      bool.fromEnvironment('REPORT_ADS_TEST_OVERRIDE');

  /// The single release-inert composition shared by every debug hook here:
  /// a release build (`isReleaseBuild == true`) yields `false` for EVERY value
  /// of [defineSet]. Exposed for testing so release-inertness is provable
  /// without producing a release build.
  @visibleForTesting
  static bool computeDebugOnly({
    required bool isReleaseBuild,
    required bool defineSet,
  }) =>
      !isReleaseBuild && defineSet;

  /// Back-compat alias used by the UMP geography tests.
  @visibleForTesting
  static bool computeForceEea({
    required bool isReleaseBuild,
    required bool defineSet,
  }) =>
      computeDebugOnly(isReleaseBuild: isReleaseBuild, defineSet: defineSet);

  /// Whether to hardcode UMP EEA geography for this run. Always `false` in a
  /// release build; only `true` in a debug/profile build with the define set.
  static bool get forceEeaGeography => computeDebugOnly(
        isReleaseBuild: kReleaseMode,
        defineSet: _forceEeaDefine,
      );

  /// QA-only stand-in for the `enable_report_ads` PLACEMENT flag (R6 physical
  /// matrix). It exists solely so a human can exercise the report-export ad
  /// placement on a real device while the staging/global flag stays OFF —
  /// there is no safe per-user remote override.
  ///
  /// Deliberately narrow: it substitutes ONLY the product feature-flag term.
  /// It does NOT force entitlement inactive, does NOT force UMP `canRequestAds`,
  /// does NOT force an ad to load, and does NOT force report generation — every
  /// real gate still runs. It never touches FeatureFlagService remote state,
  /// never persists to Drift, and never affects referrals.
  ///
  /// Release safety is structural (same `!kReleaseMode` composition as above),
  /// so this can never become a second production flag authority.
  static bool get reportAdsPlacementTestOverride => computeDebugOnly(
        isReleaseBuild: kReleaseMode,
        defineSet: _reportAdsOverrideDefine,
      );

  /// UMP test-device identifiers for this run — a device must be registered for
  /// debug geography to take effect on real hardware. Empty in release, and
  /// empty unless the define supplies one (never hardcoded here).
  static List<String> get testDeviceIds =>
      (!kReleaseMode && _testDeviceDefine.isNotEmpty)
          ? <String>[_testDeviceDefine]
          : const <String>[];
}
