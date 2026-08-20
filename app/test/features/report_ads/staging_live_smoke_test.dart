// R5 §14–§18 — LIVE staging smoke of the REAL R3/R4 mobile service layer.
//
// Gated on staging credentials passed via --dart-define (SUPABASE_URL,
// SUPABASE_ANON_KEY drive SupabaseConfig.isConfigured; the R5_* values name the
// disposable fixture users). Skips cleanly when they are absent, so it never
// runs (or fails) in the normal offline suite. Uses a raw SupabaseClient with a
// real authenticated user JWT for the mobile path and a FAKE ad gateway — no
// AdMob traffic. Hard-refuses any non-staging project ref.

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:money_companion/features/referrals/services/referral_service.dart';
import 'package:money_companion/features/report_ads/ad_consent_service.dart';
import 'package:money_companion/features/report_ads/report_ads_analytics.dart';
import 'package:money_companion/features/report_ads/report_entitlement.dart';
import 'package:money_companion/features/report_ads/report_export_ad_gateway.dart';
import 'package:money_companion/features/report_ads/report_export_coordinator.dart';
import 'package:money_companion/core/backend/metrics_client.dart';

const _url = String.fromEnvironment('SUPABASE_URL');
const _anon = String.fromEnvironment('SUPABASE_ANON_KEY');
const _activeEmail = String.fromEnvironment('R5_ACTIVE_EMAIL');
const _inactiveEmail = String.fromEnvironment('R5_INACTIVE_EMAIL');
const _password = String.fromEnvironment('R5_PASSWORD');
const _approvedRef = 'bdhqjijscwdzqwqanygv';

final _hasCreds = _url.isNotEmpty && _anon.isNotEmpty && _activeEmail.isNotEmpty && _inactiveEmail.isNotEmpty;

class _FakeGateway implements ReportExportAdGateway {
  _FakeGateway({this.available = true, this.outcome = ReportAdOutcome.dismissed});
  bool available;
  ReportAdOutcome outcome;
  int showCalls = 0;
  @override
  bool get isAvailable => available;
  @override
  Future<void> preload() async {}
  @override
  Future<ReportAdOutcome> showIfAvailable() async {
    showCalls++;
    if (!available) return ReportAdOutcome.unavailable;
    available = false;
    return outcome;
  }

  @override
  void dispose() {}
}

class _FakeConsent implements AdConsentService {
  @override
  Future<bool> canRequestAds() async => true;
  @override
  Future<void> gatherConsent() async {}
  @override
  Future<bool> isPrivacyOptionsRequired() async => false;
  @override
  Future<void> showPrivacyOptions() async {}
}

class _RecordingMetrics extends MetricsClient {
  final List<String> events = [];
  @override
  Future<void> logEvent(String key, {String? dimension}) async => events.add(key);
}

ReportAdsAnalytics _analytics() =>
    ReportAdsAnalytics(cloudProcessingEnabled: () async => false, metrics: _RecordingMetrics());

void main() {
  test('§14/§15/§16/§17/§18 — real R3/R4 services against validation staging', () async {
    // Hard ref guard.
    expect(_url.contains(_approvedRef), isTrue, reason: 'must target approved validation staging only');
    expect(_url.contains('vrombzdgwqjjiijbidqb'), isFalse);
    expect(_url.contains('dpdukyozedajelflkeix'), isFalse);

    final client = SupabaseClient(_url, _anon);
    final svc = SupabaseReferralService(getClient: () => client);
    final resolver = ReportEntitlementResolver(
      service: svc,
      currentUserId: () => client.auth.currentUser?.id,
    );
    ReportExportCoordinator coord(ReportExportAdGateway gw) => ReportExportCoordinator(
          reportAdsEnabled: () => true,
          adConfigAvailable: () => true,
          entitlement: resolver,
          consent: _FakeConsent(),
          gateway: gw,
          analytics: _analytics(),
        );

    // ── ACTIVE user (M) ────────────────────────────────────────────────────
    await client.auth.signInWithPassword(email: _activeEmail, password: _password);
    // §14 R3: real ReferralService fetches the server-authoritative summary.
    final summary = await svc.getSummary();
    expect(summary, isNotNull, reason: '§14 referral summary fetch');
    expect(summary!.referralCode.isNotEmpty, isTrue, reason: '§14 code display');
    // §15 R4 three-state: fresh active server response → VERIFIED_ACTIVE.
    resolver.clear();
    expect(await resolver.resolve(), ReportEntitlementState.verifiedActive, reason: '§15A active');
    // §16 active entitlement → NO ad, exactly one report generation.
    final gwActive = _FakeGateway(available: true);
    var genActive = 0;
    await coord(gwActive).run(() async => genActive++);
    expect(gwActive.showCalls, 0, reason: '§16 active → no ad');
    expect(genActive, 1, reason: '§16 active → exactly one export');

    // ── INACTIVE user (N) ──────────────────────────────────────────────────
    await client.auth.signOut();
    await client.auth.signInWithPassword(email: _inactiveEmail, password: _password);
    resolver.clear();
    // §15B inactive server response → VERIFIED_INACTIVE.
    expect(await resolver.resolve(), ReportEntitlementState.verifiedInactive, reason: '§15B inactive');
    // §16 inactive → one fake ad opportunity → exactly one report generation.
    final gwInactive = _FakeGateway(available: true, outcome: ReportAdOutcome.dismissed);
    var genInactive = 0;
    await coord(gwInactive).run(() async => genInactive++);
    expect(gwInactive.showCalls, 1, reason: '§16 inactive → one ad');
    expect(genInactive, 1, reason: '§16 inactive → exactly one export');

    // §17 fail-open matrix (VERIFIED_INACTIVE, staging resolver stays fresh).
    for (final o in [
      ReportAdOutcome.unavailable,
      ReportAdOutcome.failedToLoad,
      ReportAdOutcome.failedToShow,
      ReportAdOutcome.dismissed,
      ReportAdOutcome.lifecycleInterrupted,
    ]) {
      final gw = _FakeGateway(available: o != ReportAdOutcome.unavailable, outcome: o);
      var gen = 0;
      await coord(gw).run(() async => gen++);
      expect(gen, 1, reason: '§17 fail-open: $o → exactly one export');
    }

    // §18 single-flight against the real coordinator (3 rapid taps → 1 export).
    final gwSF = _FakeGateway(available: true);
    var genSF = 0;
    final c = coord(gwSF);
    await Future.wait([
      c.run(() async => genSF++),
      c.run(() async => genSF++),
      c.run(() async => genSF++),
    ]);
    expect(genSF, 1, reason: '§18 single-flight → one export');
    expect(gwSF.showCalls, lessThanOrEqualTo(1), reason: '§18 at most one ad');

    // §15C UNKNOWN_OR_STALE: signed out → lookup uncertainty, never inactive.
    await client.auth.signOut();
    resolver.clear();
    final unknown = await resolver.resolve();
    expect(unknown, ReportEntitlementState.unknownOrStale, reason: '§15C signed-out → UNKNOWN');
    final gwU = _FakeGateway(available: true);
    var genU = 0;
    await coord(gwU).run(() async => genU++);
    expect(gwU.showCalls, 0, reason: '§16 unknown → no ad');
    expect(genU, 1, reason: '§16 unknown → exactly one export');
  }, skip: _hasCreds ? false : 'requires staging --dart-define credentials (R5 live smoke)');
}
