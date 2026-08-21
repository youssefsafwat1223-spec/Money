import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/di/app_providers.dart'
    show featureFlags, loadUserSettingsUseCaseProvider, metricsClientProvider;
import '../referrals/referrals_providers.dart';
import 'ad_consent_service.dart';
import 'report_ads_analytics.dart';
import 'report_ads_build_config.dart';
import 'report_ads_debug_config.dart';
import 'report_entitlement.dart';
import 'report_export_ad_gateway.dart';
import 'report_export_coordinator.dart';

/// Report-export interstitial placement gate. Product-placement rollout only —
/// NOT a financial-capability authority. Fails closed if the flag service has
/// not initialised (pre-sync / tests). Mirrors [referralsEnabledProvider].
///
/// Same-session reactivity: `syncCatalog` re-runs FeatureFlagService.init() on
/// cold-start and on resume, then invalidates this provider, so a mid-session
/// flip of `enable_report_ads` takes effect without a restart (§9).
final reportAdsEnabledProvider = Provider<bool>((ref) {
  // R6 physical-QA hook: substitutes ONLY this product-flag term so a human can
  // exercise the placement on a real device while the remote flag stays OFF.
  // Structurally inert in release; reads nothing from and writes nothing to
  // FeatureFlagService. Every other gate (UMP / entitlement / ad config /
  // single-flight / fail-open) is untouched.
  if (ReportAdsDebugConfig.reportAdsPlacementTestOverride) return true;
  try {
    return featureFlags.getBool('enable_report_ads');
  } on StateError {
    return false;
  }
});

/// UMP consent authority (single instance).
final adConsentServiceProvider = Provider<AdConsentService>(
  (ref) => const UmpAdConsentService(),
);

/// One-session UMP consent orchestration (R4 §11). Holds NO consent state — UMP
/// remains the sole authority; this only latches "consent gathering has been
/// kicked off this session" so the app never fires a second concurrent
/// consent-info request or shows a duplicate form. Because the provider is a
/// single instance per [ProviderScope], the latch is naturally session-scoped.
class SessionAdConsent {
  SessionAdConsent(this._consent);

  final AdConsentService _consent;
  Future<void>? _inFlight;
  bool _done = false;

  /// Idempotent, fail-open. The first call performs the UMP consent-info update
  /// (+ required form) exactly once; concurrent callers await the same future;
  /// after completion further calls are no-ops. Never throws.
  Future<void> ensureGathered() {
    if (_done) return Future<void>.value();
    return _inFlight ??= _run();
  }

  Future<void> _run() async {
    try {
      await _consent.gatherConsent();
    } catch (_) {
      // Fail-open + defence in depth: gatherConsent is contractually
      // non-throwing, but a failure here must never surface — UMP simply
      // leaves ads not requestable. Latched below so we never retry-storm.
    } finally {
      _done = true;
      _inFlight = null;
    }
  }
}

/// Session-scoped UMP orchestration point (single instance).
final sessionAdConsentProvider = Provider<SessionAdConsent>(
  (ref) => SessionAdConsent(ref.watch(adConsentServiceProvider)),
);

/// Whether Settings should offer the UMP "privacy options" entry (§11). Async;
/// false while loading / when not applicable, so the entry stays hidden.
final adPrivacyOptionsRequiredProvider = FutureProvider<bool>(
  (ref) => ref.watch(adConsentServiceProvider).isPrivacyOptionsRequired(),
);

/// The interstitial gateway (holds a preloaded ad; disposed with the provider).
final reportExportAdGatewayProvider = Provider<ReportExportAdGateway>((ref) {
  final gateway = AdMobReportExportAdGateway();
  ref.onDispose(gateway.dispose);
  return gateway;
});

/// The entitlement resolver + in-memory session cache. Keyed by the current
/// authenticated user id; invalidated on logout / account switch by the shell.
final reportEntitlementResolverProvider = Provider<ReportEntitlementResolver>(
  (ref) => ReportEntitlementResolver(
    service: ref.watch(referralServiceProvider),
    currentUserId: () => Supabase.instance.client.auth.currentUser?.id,
  ),
);

/// Consent-gated, fire-and-forget report-export analytics.
final reportAdsAnalyticsProvider = Provider<ReportAdsAnalytics>((ref) {
  final loadSettings = ref.watch(loadUserSettingsUseCaseProvider);
  return ReportAdsAnalytics(
    // Consent read fresh on each send (§12/§24).
    cloudProcessingEnabled: () async =>
        (await loadSettings.call()).cloudProcessingEnabled,
    metrics: ref.watch(metricsClientProvider),
  );
});

/// The report-export orchestration state machine (single-flight, fail-open).
final reportExportCoordinatorProvider = Provider<ReportExportCoordinator>((ref) {
  return ReportExportCoordinator(
    reportAdsEnabled: () => ref.read(reportAdsEnabledProvider),
    adConfigAvailable: () => ReportAdsBuildConfig.isConfiguredFor(defaultTargetPlatform),
    entitlement: ref.watch(reportEntitlementResolverProvider),
    consent: ref.watch(adConsentServiceProvider),
    gateway: ref.watch(reportExportAdGatewayProvider),
    analytics: ref.watch(reportAdsAnalyticsProvider),
  );
});
