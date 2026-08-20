import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backend/metrics_client.dart';
import 'package:money_companion/features/referrals/referral_models.dart';
import 'package:money_companion/features/referrals/services/referral_service.dart';
import 'package:money_companion/features/report_ads/ad_consent_service.dart';
import 'package:money_companion/features/report_ads/report_ads_analytics.dart';
import 'package:money_companion/features/report_ads/report_entitlement.dart';
import 'package:money_companion/features/report_ads/report_export_ad_gateway.dart';
import 'package:money_companion/features/report_ads/report_export_coordinator.dart';

// ── fakes ────────────────────────────────────────────────────────────────────
class _FakeReferralService implements ReferralService {
  _FakeReferralService({this.decision, this.error});
  EntitlementDecision? decision;
  Object? error;
  @override
  Future<EntitlementDecision?> getEntitlementDecision() async {
    if (error != null) throw error!;
    return decision;
  }

  @override
  Future<ReferralSummary?> getSummary() async => null;
  @override
  Future<ApplyCodeOutcome> applyCode(String code) async =>
      const ApplyCodeOutcome(ok: false);
  @override
  Future<QualificationOutcome> requestQualification() async =>
      const QualificationOutcome(qualified: false, granted: false);
}

EntitlementDecision _decision({required bool active}) => EntitlementDecision(
      entitlementType: 'report_export_ad_free',
      status: active ? 'active' : 'none',
      active: active,
      endsAt: active ? DateTime.utc(2026, 9, 1) : null,
      serverNow: DateTime.utc(2026, 8, 17),
    );

ReportEntitlementResolver _resolver(_FakeReferralService svc) =>
    ReportEntitlementResolver(service: svc, currentUserId: () => 'user-1');

class _FakeConsent implements AdConsentService {
  _FakeConsent({this.can = true});
  bool can;
  @override
  Future<bool> canRequestAds() async => can;
  @override
  Future<void> gatherConsent() async {}
  @override
  Future<bool> isPrivacyOptionsRequired() async => false;
  @override
  Future<void> showPrivacyOptions() async {}
}

class _FakeGateway implements ReportExportAdGateway {
  _FakeGateway({
    this.available = false,
    this.preloadSucceeds = false,
    this.outcome = ReportAdOutcome.dismissed,
  });
  bool available;
  bool preloadSucceeds;
  ReportAdOutcome outcome;
  int preloadCalls = 0;
  int showCalls = 0;

  @override
  bool get isAvailable => available;
  @override
  Future<void> preload() async {
    preloadCalls++;
    if (preloadSucceeds) available = true;
  }

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

class _RecordingMetrics extends MetricsClient {
  final List<String> events = [];
  @override
  Future<void> logEvent(String key, {String? dimension}) async {
    events.add(key);
  }
}

ReportAdsAnalytics _analytics({bool consent = true, MetricsClient? metrics}) {
  return ReportAdsAnalytics(
    cloudProcessingEnabled: () async => consent,
    metrics: metrics ?? _RecordingMetrics(),
  );
}

int _seq = 0;
ReportExportCoordinator _coordinator({
  bool Function()? flag,
  bool config = true,
  required ReportEntitlementResolver entitlement,
  bool canRequestAds = true,
  required ReportExportAdGateway gateway,
  ReportAdsAnalytics? analytics,
}) {
  return ReportExportCoordinator(
    reportAdsEnabled: flag ?? () => true,
    adConfigAvailable: () => config,
    entitlement: entitlement,
    consent: _FakeConsent(can: canRequestAds),
    gateway: gateway,
    analytics: analytics ?? _analytics(),
    mintAttemptId: () => 'attempt-${_seq++}',
  );
}

void main() {
  test('A: flag OFF → no ad → export once', () async {
    final gw = _FakeGateway(available: true);
    var gen = 0;
    await _coordinator(
      flag: () => false,
      entitlement: _resolver(_FakeReferralService(decision: _decision(active: false))),
      gateway: gw,
    ).run(() async => gen++);
    expect(gw.showCalls, 0);
    expect(gen, 1);
  });

  test('B: VERIFIED_ACTIVE → no ad → export once', () async {
    final gw = _FakeGateway(available: true);
    var gen = 0;
    await _coordinator(
      entitlement: _resolver(_FakeReferralService(decision: _decision(active: true))),
      gateway: gw,
    ).run(() async => gen++);
    expect(gw.showCalls, 0);
    expect(gen, 1);
  });

  test('C: VERIFIED_INACTIVE + UMP allowed + ad available → one interstitial → export', () async {
    final gw = _FakeGateway(available: true, outcome: ReportAdOutcome.dismissed);
    var gen = 0;
    await _coordinator(
      entitlement: _resolver(_FakeReferralService(decision: _decision(active: false))),
      gateway: gw,
    ).run(() async => gen++);
    expect(gw.showCalls, 1);
    expect(gen, 1);
  });

  test('D: UNKNOWN_OR_STALE → no ad → export once', () async {
    final gw = _FakeGateway(available: true);
    var gen = 0;
    await _coordinator(
      entitlement: _resolver(_FakeReferralService(decision: null)), // null → unknown
      gateway: gw,
    ).run(() async => gen++);
    expect(gw.showCalls, 0);
    expect(gen, 1);
  });

  test('E: entitlement timeout → no ad → export once', () async {
    final gw = _FakeGateway(available: true);
    var gen = 0;
    await _coordinator(
      entitlement: _resolver(_FakeReferralService(error: TimeoutException('slow'))),
      gateway: gw,
    ).run(() async => gen++);
    expect(gw.showCalls, 0);
    expect(gen, 1);
  });

  test('F: ad failed_to_load → export once', () async {
    final gw = _FakeGateway(available: false, preloadSucceeds: false);
    var gen = 0;
    await _coordinator(
      entitlement: _resolver(_FakeReferralService(decision: _decision(active: false))),
      gateway: gw,
    ).run(() async => gen++);
    expect(gw.preloadCalls, greaterThanOrEqualTo(1));
    expect(gw.showCalls, 0);
    expect(gen, 1);
  });

  test('G: ad failed_to_show → export once', () async {
    final gw = _FakeGateway(available: true, outcome: ReportAdOutcome.failedToShow);
    var gen = 0;
    await _coordinator(
      entitlement: _resolver(_FakeReferralService(decision: _decision(active: false))),
      gateway: gw,
    ).run(() async => gen++);
    expect(gw.showCalls, 1);
    expect(gen, 1);
  });

  test('H: ad dismissed → export exactly once', () async {
    final gw = _FakeGateway(available: true, outcome: ReportAdOutcome.dismissed);
    var gen = 0;
    await _coordinator(
      entitlement: _resolver(_FakeReferralService(decision: _decision(active: false))),
      gateway: gw,
    ).run(() async => gen++);
    expect(gen, 1);
  });

  test('I: lifecycle interruption → export exactly once', () async {
    final gw = _FakeGateway(available: true, outcome: ReportAdOutcome.lifecycleInterrupted);
    var gen = 0;
    await _coordinator(
      entitlement: _resolver(_FakeReferralService(decision: _decision(active: false))),
      gateway: gw,
    ).run(() async => gen++);
    expect(gen, 1);
  });

  test('J: repeated Export taps → single-flight (one generation)', () async {
    final gw = _FakeGateway(available: true, outcome: ReportAdOutcome.dismissed);
    final coord = _coordinator(
      entitlement: _resolver(_FakeReferralService(decision: _decision(active: false))),
      gateway: gw,
    );
    var gen = 0;
    final slow = Completer<void>();
    Future<void> generate() async {
      gen++;
      await slow.future; // hold the first attempt in-flight
    }

    final f1 = coord.run(generate);
    final f2 = coord.run(generate); // ignored: an attempt is already active
    final f3 = coord.run(generate); // ignored
    slow.complete();
    await Future.wait([f1, f2, f3]);
    expect(gen, 1);
    expect(gw.showCalls, 1);
  });

  test('K: a re-entrant tap from within generation is ignored (no stale double-run)', () async {
    final gw = _FakeGateway(available: false); // skip ad path for clarity
    late ReportExportCoordinator coord;
    var gen = 0;
    coord = _coordinator(
      entitlement: _resolver(_FakeReferralService(decision: _decision(active: false))),
      gateway: gw,
    );
    Future<void> generate() async {
      gen++;
      // A stale/re-entrant continuation must not start a second attempt.
      await coord.run(() async => gen++);
    }

    await coord.run(generate);
    expect(gen, 1);
  });

  test('N: UMP cannotRequestAds → no ad → export once', () async {
    final gw = _FakeGateway(available: true);
    var gen = 0;
    await _coordinator(
      entitlement: _resolver(_FakeReferralService(decision: _decision(active: false))),
      canRequestAds: false,
      gateway: gw,
    ).run(() async => gen++);
    expect(gw.showCalls, 0);
    expect(gen, 1);
  });

  test('O: missing ad config → no ad → export once', () async {
    final gw = _FakeGateway(available: true);
    var gen = 0;
    await _coordinator(
      config: false,
      entitlement: _resolver(_FakeReferralService(decision: _decision(active: false))),
      gateway: gw,
    ).run(() async => gen++);
    expect(gw.showCalls, 0);
    expect(gen, 1);
  });

  test('P: cloudProcessingEnabled OFF → zero analytics, while ad/export still run', () async {
    final metrics = _RecordingMetrics();
    final gw = _FakeGateway(available: true, outcome: ReportAdOutcome.dismissed);
    var gen = 0;
    await _coordinator(
      entitlement: _resolver(_FakeReferralService(decision: _decision(active: false))),
      gateway: gw,
      analytics: _analytics(consent: false, metrics: metrics),
    ).run(() async => gen++);
    // AdMob/UMP logic independent of analytics consent: the ad still showed and
    // the export still ran…
    expect(gw.showCalls, 1);
    expect(gen, 1);
    // …but no optional Qirsh analytics were emitted.
    await Future<void>.delayed(Duration.zero); // let fire-and-forget settle
    expect(metrics.events, isEmpty);
  });

  test('P2: cloudProcessingEnabled ON → analytics emitted, best-effort', () async {
    final metrics = _RecordingMetrics();
    final gw = _FakeGateway(available: true, outcome: ReportAdOutcome.dismissed);
    await _coordinator(
      entitlement: _resolver(_FakeReferralService(decision: _decision(active: false))),
      gateway: gw,
      analytics: _analytics(consent: true, metrics: metrics),
    ).run(() async {});
    await Future<void>.delayed(Duration.zero);
    expect(metrics.events, contains('report_export_requested'));
    expect(metrics.events, contains('report_export_completed'));
    // Never a rewarded concept.
    expect(metrics.events.any((e) => e.contains('reward')), isFalse);
  });

  test('Q: same-session flag disable removes future ad opportunities', () async {
    var enabled = true;
    final gw = _FakeGateway(available: true, preloadSucceeds: true, outcome: ReportAdOutcome.dismissed);
    final coord = _coordinator(
      flag: () => enabled,
      entitlement: _resolver(_FakeReferralService(decision: _decision(active: false))),
      gateway: gw,
    );
    var gen = 0;
    await coord.run(() async => gen++);
    expect(gw.showCalls, 1); // ad shown while enabled

    enabled = false; // mid-session kill switch
    gw.available = true;
    await coord.run(() async => gen++);
    expect(gw.showCalls, 1); // no further ad after disable
    expect(gen, 2); // both exports completed
  });
}
