import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart'
    show featureFlags, loadUserSettingsUseCaseProvider, metricsClientProvider;
import '../report_ads/report_ads_providers.dart'
    show adConsentServiceProvider, reportEntitlementResolverProvider;
import '../report_ads/report_entitlement.dart';
import 'ad_placement.dart';
import 'admob_build_config.dart';
import 'banner_ad_controller.dart';
import 'banner_ads_analytics.dart';

/// Banner master kill switch. Seeded OFF and fail-closed, like every other
/// product-rollout flag. `StateError` means the flag service has not
/// initialised yet (pre-sync, or a test) — which is not "on".
final bannerAdsEnabledProvider = Provider<bool>((ref) {
  try {
    return featureFlags.getBool('enable_banner_ads');
  } on StateError {
    return false;
  }
});

/// Per-placement kill switch.
///
/// Typed booleans rather than one remote string listing disabled placements.
/// Both reviewers rejected the string: this codebase already documents, on the
/// coupons flags, that "a single flag that disables everything is an outage,
/// not a kill switch", and a comma-separated mini-DSL adds a parser plus a
/// failure mode where one typo silently disables everything.
///
/// Every key returned here MUST also exist in the `_defaults` map in
/// `feature_flag_service.dart`. `getBool` falls back to `_defaults` only when
/// the remote cache has no boolean for the key, so a key that is absent from
/// BOTH is false by accident rather than by decision.
final bannerPlacementEnabledProvider =
    Provider.family<bool, AdPlacement>((ref, placement) {
  if (!ref.watch(bannerAdsEnabledProvider)) return false;
  try {
    return featureFlags.getBool('enable_banner_${placement.key}');
  } on StateError {
    return false;
  }
});

/// The ad-free entitlement decision for banner purposes.
///
/// Deliberately the SAME three-state resolver and the SAME policy as the
/// report-export interstitial: only `verifiedInactive` may see an ad; both
/// `verifiedActive` (ad-free) and `unknownOrStale` (any uncertainty) mean no
/// ad.
///
/// One reviewer initially argued this loses revenue, because a signed-out user
/// resolves to `unknownOrStale` and would never see a banner. The router says
/// otherwise: `needsOnboarding` and `sessionExpired` both redirect to
/// `/onboarding/auth`, AppShell only exists at `/`, and nothing in the app ever
/// sets the vestigial `authMethod = 'guest'`. There is no signed-out population
/// on these screens to lose, so weakening the policy would trade a real risk —
/// showing ads to someone who earned ad-free, during a transient lookup
/// failure — for no revenue at all.
/// `autoDispose` is load-bearing, not tidiness.
///
/// As a plain `FutureProvider` this cached its FIRST answer for the life of the
/// process and nothing ever invalidated it. Two real consequences, both found
/// independently by two reviewers: a user who earned ad-free mid-session kept
/// seeing banners until they restarted the app — breaking the one promise this
/// gate exists to keep — and a first evaluation that raced UMP consent cached
/// "no consent" forever, silently killing banners for the whole session.
///
/// The resolver behind it has its own 5-minute TTL cache, so re-evaluating on
/// each fresh watch costs no network.
final bannerEntitlementProvider =
    FutureProvider.autoDispose<ReportEntitlementState>(
  (ref) => ref.watch(reportEntitlementResolverProvider).resolve(),
);

/// Whether UMP currently permits ad requests.
/// `autoDispose` for the same reason as the entitlement provider: UMP consent
/// can be granted or revoked at any time, including from the Settings privacy
/// options form, and a cached answer would outlive the user's decision.
final bannerConsentProvider = FutureProvider.autoDispose<bool>(
  (ref) => ref.watch(adConsentServiceProvider).canRequestAds(),
);

/// Every non-visual gate for [placement], resolved together.
///
/// Visual gates — offstage, covered by a route, covered by a modal, an empty
/// list — live in the widget, because only the widget can see them. This
/// provider answers "may this placement serve at all", and it must be true
/// before the widget is even inserted into a list.
final bannerEligibilityProvider =
    FutureProvider.autoDispose.family<bool, AdPlacement>((ref, placement) async {
  if (!ref.watch(bannerPlacementEnabledProvider(placement))) return false;
  if (!AdMobBuildConfig.isBannerConfiguredFor(defaultTargetPlatform)) {
    return false;
  }
  final entitlement = await ref.watch(bannerEntitlementProvider.future);
  if (entitlement != ReportEntitlementState.verifiedInactive) return false;
  return ref.watch(bannerConsentProvider.future);
});

/// Factory seam so widget tests can supply a fake loader.
final bannerAdLoaderFactoryProvider = Provider<BannerAdLoader Function()>(
  (ref) => AdMobBannerAdLoader.new,
);

/// Consent-gated, fire-and-forget banner telemetry.
final bannerAdsAnalyticsProvider = Provider<BannerAdsAnalytics>((ref) {
  final loadSettings = ref.watch(loadUserSettingsUseCaseProvider);
  return BannerAdsAnalytics(
    cloudProcessingEnabled: () async =>
        (await loadSettings.call()).cloudProcessingEnabled,
    metrics: ref.watch(metricsClientProvider),
  );
});
