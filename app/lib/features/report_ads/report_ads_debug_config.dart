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

  /// Pure composition, exposed for testing so the release-inertness is provable
  /// without a release build: a release build (`isReleaseBuild == true`) yields
  /// `false` for EVERY value of [defineSet].
  @visibleForTesting
  static bool computeForceEea({
    required bool isReleaseBuild,
    required bool defineSet,
  }) =>
      !isReleaseBuild && defineSet;

  /// Whether to hardcode UMP EEA geography for this run. Always `false` in a
  /// release build; only `true` in a debug/profile build with the define set.
  static bool get forceEeaGeography => computeForceEea(
        isReleaseBuild: kReleaseMode,
        defineSet: _forceEeaDefine,
      );

  /// UMP test-device identifiers for this run — a device must be registered for
  /// debug geography to take effect on real hardware. Empty in release, and
  /// empty unless the define supplies one (never hardcoded here).
  static List<String> get testDeviceIds =>
      (!kReleaseMode && _testDeviceDefine.isNotEmpty)
          ? <String>[_testDeviceDefine]
          : const <String>[];
}
