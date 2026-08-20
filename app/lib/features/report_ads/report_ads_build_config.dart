import 'package:flutter/foundation.dart';

/// Build-time AdMob configuration for the report-export interstitial (R4).
///
/// Ad-unit IDs are DEPLOYMENT/BUILD configuration, never Admin-editable DB rows
/// and never business data (docs REFERRAL_ADS_ADMIN_SYSTEM.md §3). During
/// development only Google's public TEST unit is used; production IDs arrive
/// exclusively through `--dart-define` and are absent by default, so a release
/// build with no production config **fails closed** (no ad → export proceeds).
class ReportAdsBuildConfig {
  ReportAdsBuildConfig._();

  // Google's official sample/TEST interstitial unit IDs. Safe to hardcode — they
  // are Google's documented test units and never serve a real (billable) ad.
  static const String testInterstitialIos =
      'ca-app-pub-3940256099942544/4411468910';
  static const String testInterstitialAndroid =
      'ca-app-pub-3940256099942544/1033173712';

  // Production interstitial unit IDs — supplied ONLY at build time. Never a
  // literal in source, never a DB row. Empty when not provided (fail closed).
  static const String _prodInterstitialIos =
      String.fromEnvironment('ADMOB_INTERSTITIAL_IOS');
  static const String _prodInterstitialAndroid =
      String.fromEnvironment('ADMOB_INTERSTITIAL_ANDROID');

  /// The interstitial ad-unit id for [platform], or null when unavailable.
  ///
  /// Debug/profile builds always use the TEST unit. Release builds use the
  /// dart-defined production unit, or null if it is absent — the caller treats
  /// null as "no ad configuration" and skips the ad entirely.
  static String? interstitialUnitId(TargetPlatform platform) {
    final isIos = platform == TargetPlatform.iOS;
    if (kDebugMode || kProfileMode) {
      return isIos ? testInterstitialIos : testInterstitialAndroid;
    }
    final prod = isIos ? _prodInterstitialIos : _prodInterstitialAndroid;
    return prod.isEmpty ? null : prod;
  }

  /// Whether a usable interstitial unit id exists for [platform] in this build.
  static bool isConfiguredFor(TargetPlatform platform) =>
      interstitialUnitId(platform) != null;

  /// True in dev builds where the TEST unit is in force. Surfaced so callers /
  /// tests can assert that development never touches a production unit.
  static bool get isTestMode => kDebugMode || kProfileMode;
}
