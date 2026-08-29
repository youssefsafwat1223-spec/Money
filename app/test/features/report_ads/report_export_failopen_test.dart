import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backend/metrics_client.dart';
import 'package:money_companion/features/referrals/referral_models.dart';
import 'package:money_companion/features/referrals/services/referral_service.dart';
import 'package:money_companion/features/report_ads/ad_consent_service.dart';
import 'package:money_companion/features/report_ads/report_ads_analytics.dart';
import 'package:money_companion/features/report_ads/report_entitlement.dart';
import 'package:money_companion/features/report_ads/report_export_ad_gateway.dart';
import 'package:money_companion/features/report_ads/report_export_coordinator.dart';

/// Cross-model audit findings **H-5** and **H-6** — the ad path could cost the
/// user their report, permanently.
///
/// The existing coordinator tests only ever used fakes that return normally:
/// "failed to load" merely set `available = false`, and no fake ever threw or
/// hung. So the two real failure shapes were untested:
///
///  * H-6 — `run()` was try/FINALLY with no catch. Any throw out of the ad gate
///    skipped `advanceOnce()`, so the accepted export generated NOTHING and the
///    exception escaped to the caller.
///  * H-5 — the gateway completed only from SDK callbacks. A lost callback left
///    `_inFlight` true, so single-flight silently swallowed every later Export
///    tap for the rest of the session.
///
/// The invariant under test is the one the coordinator documents: FAIL-OPEN —
/// every terminal ad outcome, including a broken SDK, still generates the
/// report. The single documented exception is explicit user cancellation.
class _FakeReferralService implements ReferralService {
  _FakeReferralService({this.decision, this.decisionFuture});
  EntitlementDecision? decision;
  final Future<EntitlementDecision?>? decisionFuture;
  int decisionCalls = 0;
  @override
  Future<EntitlementDecision?> getEntitlementDecision() async {
    decisionCalls++;
    final pending = decisionFuture;
    if (pending != null) return pending;
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

EntitlementDecision _inactive() => EntitlementDecision(
      entitlementType: 'report_export_ad_free',
      status: 'none',
      active: false,
      endsAt: null,
      serverNow: DateTime.utc(2026, 8, 17),
    );

class _FakeConsent implements AdConsentService {
  _FakeConsent({this.throws = false, this.canRequestAdsFuture});
  bool throws;
  final Future<bool>? canRequestAdsFuture;
  int canRequestAdsCalls = 0;
  @override
  Future<bool> canRequestAds() async {
    canRequestAdsCalls++;
    if (throws) throw StateError('UMP platform channel died');
    final pending = canRequestAdsFuture;
    if (pending != null) return pending;
    return true;
  }

  @override
  Future<void> gatherConsent() async {}
  @override
  Future<bool> isPrivacyOptionsRequired() async => false;
  @override
  Future<void> showPrivacyOptions() async {}
}

/// A gateway that behaves like a genuinely broken SDK.
class _BrokenGateway implements ReportExportAdGateway {
  _BrokenGateway({
    this.throwOnPreload = false,
    this.throwOnShow = false,
    this.preloadFuture,
    this.showTriggerFuture,
    this.showCallbackFuture,
  });
  final bool throwOnPreload;
  final bool throwOnShow;
  final Future<void>? preloadFuture;
  final Future<void>? showTriggerFuture;
  final Future<void>? showCallbackFuture;
  bool _available = false;
  int preloadCalls = 0;
  int showCalls = 0;
  int showTriggerCalls = 0;
  int showCallbackWaits = 0;
  int abandonCalls = 0;
  bool loading = false;
  bool showing = false;

  @override
  bool get isAvailable => _available;

  @override
  Future<void> preload() async {
    preloadCalls++;
    loading = true;
    try {
      if (throwOnPreload) throw StateError('MobileAds.initialize failed');
      if (preloadFuture != null) await preloadFuture;
      _available = true; // loaded, so the show path is reachable
    } finally {
      loading = false;
    }
  }

  @override
  Future<ReportAdOutcome> showIfAvailable() async {
    showCalls++;
    _available = false; // consume this loaded opportunity exactly once
    showing = true;
    try {
      if (throwOnShow) throw StateError('ad.show() threw');
      showTriggerCalls++;
      if (showTriggerFuture != null) await showTriggerFuture;
      showCallbackWaits++;
      if (showCallbackFuture != null) await showCallbackFuture;
      return ReportAdOutcome.dismissed;
    } finally {
      showing = false;
    }
  }

  @override
  void dispose() {
    abandonCalls++;
    loading = false;
    showing = false;
    _available = false;
  }
}

ReportExportCoordinator _coordinator(
  ReportExportAdGateway gateway, {
  AdConsentService? consent,
  ReportEntitlementResolver? entitlement,
  bool Function()? reportAdsEnabled,
  Duration adOpportunityDeadline = const Duration(minutes: 6),
}) {
  final svc = _FakeReferralService(decision: _inactive());
  return ReportExportCoordinator(
    reportAdsEnabled: reportAdsEnabled ?? () => true,
    adConfigAvailable: () => true,
    entitlement: entitlement ??
        ReportEntitlementResolver(service: svc, currentUserId: () => 'user-1'),
    consent: consent ?? _FakeConsent(),
    gateway: gateway,
    analytics: ReportAdsAnalytics(
      cloudProcessingEnabled: () async => false,
      metrics: MetricsClient(),
    ),
    adOpportunityDeadline: adOpportunityDeadline,
  );
}

const _testDeadline = Duration(seconds: 3);

Future<void> _expectDeadlineFailOpen(
  WidgetTester tester, {
  required ReportExportCoordinator coordinator,
  required void Function() disableAds,
  required void Function() expectOpportunityStarted,
  required void Function() expectOpportunityConsumed,
}) async {
  var generated = 0;
  final run = coordinator.run(() async => generated++);

  await tester.pump();
  expect(generated, 0,
      reason: 'the never-completing fake must genuinely hold the ad path');
  expectOpportunityStarted();

  await tester.pump(_testDeadline);
  expect(generated, 1,
      reason: 'the global deadline must fail open to report generation');
  await run;
  expect(coordinator.phase, ReportExportPhase.idle,
      reason: 'timeout must release the single-flight latch');
  expectOpportunityConsumed();

  // A later export proves `_inFlight` was cleared. Disable ads so it also
  // proves the timed-out opportunity is not retried or multiplied.
  disableAds();
  final nextRun = coordinator.run(() async => generated++);
  await tester.pump();
  await nextRun;
  expect(generated, 2);
  expectOpportunityConsumed();
}

void main() {
  group('H-6 — a broken ad stage never withholds the report', () {
    test('a throwing preload still generates exactly one report', () async {
      var generated = 0;
      final coordinator = _coordinator(_BrokenGateway(throwOnPreload: true));

      await coordinator.run(() async => generated++);

      expect(generated, 1,
          reason: 'SDK init failure must not cost the user their report');
      expect(coordinator.phase, ReportExportPhase.idle,
          reason: 'the machine must return to idle, not wedge');
    });

    test('a throwing show still generates exactly one report', () async {
      var generated = 0;
      final coordinator = _coordinator(_BrokenGateway(throwOnShow: true));

      await coordinator.run(() async => generated++);

      expect(generated, 1);
      expect(coordinator.phase, ReportExportPhase.idle);
    });

    test('a throwing consent check still generates the report', () async {
      var generated = 0;
      final coordinator = _coordinator(
        _BrokenGateway(),
        consent: _FakeConsent(throws: true),
      );

      await coordinator.run(() async => generated++);

      expect(generated, 1);
    });

    test('run() does not rethrow an ad-stage failure to the caller', () async {
      final coordinator = _coordinator(_BrokenGateway(throwOnPreload: true));
      // The export call site is UI code; an escaping exception surfaced as a
      // crash/red screen instead of a report.
      await expectLater(coordinator.run(() async {}), completes);
    });

    test('the session is still usable after a failure (not wedged)', () async {
      var generated = 0;
      final coordinator = _coordinator(_BrokenGateway(throwOnPreload: true));

      await coordinator.run(() async => generated++);
      await coordinator.run(() async => generated++);

      expect(generated, 2,
          reason: '_inFlight must be released, or every later Export tap is '
              'silently ignored for the rest of the session');
    });
  });

  group('H-5 — the real gateway bounds every SDK await', () {
    // The concrete AdMobReportExportAdGateway cannot be driven without the
    // platform SDK, so this asserts the structural property that makes the
    // behaviour above possible. Kept narrow and specific on purpose.
    final source = File('lib/features/report_ads/report_export_ad_gateway.dart')
        .readAsStringSync();

    test('initialize, load and show are all time-bounded', () {
      expect(source, contains('_initTimeout'));
      expect(source, contains('_loadTimeout'));
      expect(source, contains('_showTimeout'));
      expect(RegExp(r'\.timeout\(').allMatches(source).length,
          greaterThanOrEqualTo(3),
          reason: 'each of init / load / show must be bounded');
    });

    test('the show deadline is armed before ad.show is invoked', () {
      final presentationAt = source.indexOf(
        'final presentation = Future<ReportAdOutcome>.microtask',
      );
      final triggerAt = source.indexOf('await ad.show()');
      final deadlineAt = source.indexOf('return await presentation.timeout');
      expect(presentationAt, greaterThanOrEqualTo(0));
      expect(triggerAt, greaterThan(presentationAt));
      expect(deadlineAt, greaterThan(triggerAt));
    });

    test('the in-flight load flag is released on every path', () {
      expect(source, contains('finally'),
          reason: '_loading must reset even when initialize() throws, or no ad '
              'can ever load again for the process lifetime');
    });

    test('a timed-out load cannot publish a late ad', () {
      expect(source, contains('void invalidateLoad()'));
      expect(source, contains('_loadGeneration++'));
      expect(source, contains('generation != _loadGeneration'));
    });

    test('the discarded load Future can no longer strand the completer', () {
      // InterstitialAd.load returns a Future that may reject BEFORE either
      // callback fires; unawaited, that hung the gateway forever.
      expect(source, contains('catchError'));
      expect(source, contains('unawaited('));
    });

    test('lifecycleInterrupted is now actually reachable', () {
      // It was declared and switched on, but nothing ever returned it.
      expect(source, contains('return ReportAdOutcome.lifecycleInterrupted'));
    });

    test('preload requires the COMPLETE ad configuration', () {
      // Gating on the unit id alone allowed SDK init against an absent
      // application id (audit C-4/A1).
      expect(source, contains('isConfiguredFor'));
    });
  });

  group('H-5 R9 — one deadline bounds the entire ad opportunity', () {
    testWidgets('a never-completing UMP consent check fails open once',
        (tester) async {
      final never = Completer<bool>();
      final consent = _FakeConsent(canRequestAdsFuture: never.future);
      final gateway = _BrokenGateway();
      var adsEnabled = true;
      final coordinator = _coordinator(
        gateway,
        consent: consent,
        reportAdsEnabled: () => adsEnabled,
        adOpportunityDeadline: _testDeadline,
      );

      await _expectDeadlineFailOpen(
        tester,
        coordinator: coordinator,
        disableAds: () => adsEnabled = false,
        expectOpportunityStarted: () {
          expect(consent.canRequestAdsCalls, 1);
          expect(gateway.preloadCalls, 0);
          expect(gateway.showCalls, 0);
          expect(gateway.abandonCalls, 0);
        },
        expectOpportunityConsumed: () {
          expect(consent.canRequestAdsCalls, 1);
          expect(gateway.preloadCalls, 0);
          expect(gateway.showCalls, 0);
          expect(gateway.abandonCalls, 0);
        },
      );
    });

    testWidgets('a never-completing entitlement resolution fails open once',
        (tester) async {
      final never = Completer<EntitlementDecision?>();
      final service = _FakeReferralService(decisionFuture: never.future);
      final entitlement = ReportEntitlementResolver(
        service: service,
        currentUserId: () => 'user-1',
      );
      final gateway = _BrokenGateway();
      var adsEnabled = true;
      final coordinator = _coordinator(
        gateway,
        entitlement: entitlement,
        reportAdsEnabled: () => adsEnabled,
        adOpportunityDeadline: _testDeadline,
      );

      await _expectDeadlineFailOpen(
        tester,
        coordinator: coordinator,
        disableAds: () => adsEnabled = false,
        expectOpportunityStarted: () {
          expect(service.decisionCalls, 1);
          expect(gateway.preloadCalls, 0);
          expect(gateway.showCalls, 0);
          expect(gateway.abandonCalls, 0);
        },
        expectOpportunityConsumed: () {
          expect(service.decisionCalls, 1);
          expect(gateway.preloadCalls, 0);
          expect(gateway.showCalls, 0);
          expect(gateway.abandonCalls, 0);
        },
      );
    });

    testWidgets('a never-completing ad load fails open once', (tester) async {
      final never = Completer<void>();
      final gateway = _BrokenGateway(preloadFuture: never.future);
      var adsEnabled = true;
      final coordinator = _coordinator(
        gateway,
        reportAdsEnabled: () => adsEnabled,
        adOpportunityDeadline: _testDeadline,
      );

      await _expectDeadlineFailOpen(
        tester,
        coordinator: coordinator,
        disableAds: () => adsEnabled = false,
        expectOpportunityStarted: () {
          expect(gateway.preloadCalls, 1);
          expect(gateway.showCalls, 0);
          expect(gateway.abandonCalls, 0);
          expect(gateway.loading, isTrue);
        },
        expectOpportunityConsumed: () {
          expect(gateway.preloadCalls, 1);
          expect(gateway.showCalls, 0);
          expect(gateway.abandonCalls, 1);
          expect(gateway.loading, isFalse);
        },
      );
    });

    testWidgets('a never-completing ad.show trigger fails open once',
        (tester) async {
      final never = Completer<void>();
      final gateway = _BrokenGateway(showTriggerFuture: never.future)
        .._available = true;
      var adsEnabled = true;
      final coordinator = _coordinator(
        gateway,
        reportAdsEnabled: () => adsEnabled,
        adOpportunityDeadline: _testDeadline,
      );

      await _expectDeadlineFailOpen(
        tester,
        coordinator: coordinator,
        disableAds: () => adsEnabled = false,
        expectOpportunityStarted: () {
          expect(gateway.showCalls, 1);
          expect(gateway.showTriggerCalls, 1);
          expect(gateway.showCallbackWaits, 0,
              reason: 'the fake must hang in the trigger, before callbacks');
          expect(gateway.isAvailable, isFalse,
              reason:
                  'the loaded ad is consumed before its trigger is awaited');
          expect(gateway.abandonCalls, 0);
          expect(gateway.showing, isTrue);
        },
        expectOpportunityConsumed: () {
          expect(gateway.showCalls, 1);
          expect(gateway.showTriggerCalls, 1);
          expect(gateway.showCallbackWaits, 0);
          expect(gateway.isAvailable, isFalse);
          expect(gateway.abandonCalls, 1);
          expect(gateway.showing, isFalse);
        },
      );
    });

    testWidgets('a never-firing show callback fails open once', (tester) async {
      final never = Completer<void>();
      final gateway = _BrokenGateway(showCallbackFuture: never.future)
        .._available = true;
      var adsEnabled = true;
      final coordinator = _coordinator(
        gateway,
        reportAdsEnabled: () => adsEnabled,
        adOpportunityDeadline: _testDeadline,
      );

      await _expectDeadlineFailOpen(
        tester,
        coordinator: coordinator,
        disableAds: () => adsEnabled = false,
        expectOpportunityStarted: () {
          expect(gateway.showCalls, 1);
          expect(gateway.showTriggerCalls, 1);
          expect(gateway.showCallbackWaits, 1,
              reason: 'the trigger returned; only the callback is missing');
          expect(gateway.isAvailable, isFalse);
          expect(gateway.abandonCalls, 0);
          expect(gateway.showing, isTrue);
        },
        expectOpportunityConsumed: () {
          expect(gateway.showCalls, 1);
          expect(gateway.showTriggerCalls, 1);
          expect(gateway.showCallbackWaits, 1);
          expect(gateway.isAvailable, isFalse);
          expect(gateway.abandonCalls, 1);
          expect(gateway.showing, isFalse);
        },
      );
    });
  });
}
