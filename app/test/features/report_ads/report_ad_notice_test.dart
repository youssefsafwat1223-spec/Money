import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backend/metrics_client.dart';
import 'package:money_companion/features/referrals/referral_models.dart';
import 'package:money_companion/features/referrals/services/referral_service.dart';
import 'package:money_companion/features/report_ads/ad_consent_service.dart';
import 'package:money_companion/features/report_ads/report_ad_notice.dart';
import 'package:money_companion/features/report_ads/report_ads_analytics.dart';
import 'package:money_companion/features/report_ads/report_entitlement.dart';
import 'package:money_companion/features/report_ads/report_export_ad_gateway.dart';
import 'package:money_companion/features/report_ads/report_export_coordinator.dart';

// ── fakes ────────────────────────────────────────────────────────────────────
class _FakeReferralService implements ReferralService {
  _FakeReferralService(this.decision, {this.error});
  final EntitlementDecision? decision;
  final Object? error;
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
      endsAt: active ? DateTime.utc(2026, 12, 1) : null,
      serverNow: DateTime.utc(2026, 8, 21),
    );

ReportEntitlementResolver _resolver({required bool active}) =>
    ReportEntitlementResolver(
      service: _FakeReferralService(_decision(active: active)),
      currentUserId: () => 'user-1',
    );

/// Server unreachable → UNKNOWN_OR_STALE.
ReportEntitlementResolver _unknownResolver() => ReportEntitlementResolver(
      service: _FakeReferralService(null, error: StateError('offline')),
      currentUserId: () => 'user-1',
    );

class _FakeConsent implements AdConsentService {
  _FakeConsent({this.can = true});
  final bool can;
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
  _FakeGateway({this.preloadSucceeds = true});
  final bool preloadSucceeds;
  bool available = false;
  int showCalls = 0;

  @override
  bool get isAvailable => available;
  @override
  Future<void> preload() async {
    if (preloadSucceeds) available = true;
  }

  @override
  Future<ReportAdOutcome> showIfAvailable() async {
    showCalls++;
    if (!available) return ReportAdOutcome.unavailable;
    available = false;
    return ReportAdOutcome.dismissed;
  }

  @override
  void dispose() {}
}

ReportAdsAnalytics _analytics() => ReportAdsAnalytics(
      cloudProcessingEnabled: () async => false,
      metrics: MetricsClient(),
    );

int _seq = 0;
ReportExportCoordinator _coordinator({
  required ReportEntitlementResolver entitlement,
  required ReportExportAdGateway gateway,
  bool flag = true,
  bool config = true,
  bool canRequestAds = true,
}) =>
    ReportExportCoordinator(
      reportAdsEnabled: () => flag,
      adConfigAvailable: () => config,
      entitlement: entitlement,
      consent: _FakeConsent(can: canRequestAds),
      gateway: gateway,
      analytics: _analytics(),
      mintAttemptId: () => 'notice-${_seq++}',
    );

void main() {
  // A — eligible inactive: notice once → continue → one ad → one report.
  test('A: eligible inactive shows the notice once, then ad, then report',
      () async {
    final gw = _FakeGateway();
    var notices = 0, generated = 0;
    await _coordinator(entitlement: _resolver(active: false), gateway: gw).run(
      () async => generated++,
      confirmAdNotice: () async {
        notices++;
        return true;
      },
    );
    expect(notices, 1);
    expect(gw.showCalls, 1);
    expect(generated, 1);
  });

  // B — VERIFIED_ACTIVE: no notice, no ad, report still generated.
  test('B: active entitlement → no notice, no ad, report', () async {
    final gw = _FakeGateway();
    var notices = 0, generated = 0;
    await _coordinator(entitlement: _resolver(active: true), gateway: gw).run(
      () async => generated++,
      confirmAdNotice: () async {
        notices++;
        return true;
      },
    );
    expect(notices, 0, reason: 'ad-free users never see an ad warning');
    expect(gw.showCalls, 0);
    expect(generated, 1);
  });

  // C — UNKNOWN_OR_STALE (offline): no notice, no ad, report.
  test('C: unknown/stale entitlement → no notice, no ad, report', () async {
    final gw = _FakeGateway();
    var notices = 0, generated = 0;
    await _coordinator(entitlement: _unknownResolver(), gateway: gw).run(
      () async => generated++,
      confirmAdNotice: () async {
        notices++;
        return true;
      },
    );
    expect(notices, 0, reason: 'offline users never see an ad warning');
    expect(gw.showCalls, 0);
    expect(generated, 1);
  });

  // D — UMP forbids ads: no notice, report still generated.
  test('D: UMP cannotRequestAds → no notice, report', () async {
    final gw = _FakeGateway();
    var notices = 0, generated = 0;
    await _coordinator(
      entitlement: _resolver(active: false),
      gateway: gw,
      canRequestAds: false,
    ).run(
      () async => generated++,
      confirmAdNotice: () async {
        notices++;
        return true;
      },
    );
    expect(notices, 0);
    expect(generated, 1);
  });

  // E — ad known-unavailable (load fails): no misleading notice.
  test('E: ad unavailable → no misleading notice, report still generated',
      () async {
    final gw = _FakeGateway(preloadSucceeds: false);
    var notices = 0, generated = 0;
    await _coordinator(entitlement: _resolver(active: false), gateway: gw).run(
      () async => generated++,
      confirmAdNotice: () async {
        notices++;
        return true;
      },
    );
    expect(notices, 0, reason: 'never warn about an ad that cannot appear');
    expect(gw.showCalls, 0);
    expect(generated, 1);
  });

  // F — flag/placement off: no notice at all.
  test('F: placement disabled → no notice, report', () async {
    final gw = _FakeGateway();
    var notices = 0, generated = 0;
    await _coordinator(
      entitlement: _resolver(active: false),
      gateway: gw,
      flag: false,
    ).run(
      () async => generated++,
      confirmAdNotice: () async {
        notices++;
        return true;
      },
    );
    expect(notices, 0);
    expect(generated, 1);
  });

  // G — notice accepted but the ad then fails: fail-open still holds.
  test('G: notice → ad fails to show → report still generates', () async {
    // Gateway reports available at gate time, then yields a failure outcome.
    final gw = _FakeGateway();
    var generated = 0;
    final coord = _coordinator(
      entitlement: _resolver(active: false),
      gateway: gw,
    );
    await coord.run(
      () async => generated++,
      confirmAdNotice: () async {
        gw.available = false; // ad evaporates between notice and present
        return true;
      },
    );
    expect(generated, 1, reason: 'fail-open survives the notice');
  });

  // H — explicit cancellation: no ad, NO report, machine back to idle.
  test('H: cancelling the notice cancels the attempt cleanly', () async {
    final gw = _FakeGateway();
    var generated = 0;
    final coord = _coordinator(
      entitlement: _resolver(active: false),
      gateway: gw,
    );
    await coord.run(
      () async => generated++,
      confirmAdNotice: () async => false,
    );
    expect(gw.showCalls, 0);
    expect(generated, 0, reason: 'explicit cancel must not generate');
    expect(coord.phase, ReportExportPhase.idle, reason: 'never stuck');

    // And the coordinator is reusable afterwards (not wedged in-flight).
    await coord.run(() async => generated++, confirmAdNotice: () async => true);
    expect(generated, 1);
  });

  // I — single-flight: repeated Export taps while the notice is open are ignored.
  test('I: rapid taps while the notice is open → one notice, one report',
      () async {
    final gw = _FakeGateway();
    final gate = Completer<bool>();
    var notices = 0, generated = 0;
    final coord = _coordinator(
      entitlement: _resolver(active: false),
      gateway: gw,
    );

    final first = coord.run(
      () async => generated++,
      confirmAdNotice: () async {
        notices++;
        return gate.future;
      },
    );
    // Three more taps land while the notice is still open.
    await coord.run(() async => generated++, confirmAdNotice: () async => true);
    await coord.run(() async => generated++, confirmAdNotice: () async => true);
    await coord.run(() async => generated++, confirmAdNotice: () async => true);

    gate.complete(true);
    await first;

    expect(notices, 1, reason: 'at most one notice per accepted attempt');
    expect(gw.showCalls, 1, reason: 'at most one ad opportunity');
    expect(generated, 1, reason: 'exactly one report generation');
  });

  // The dialog itself: copy has no rewarded language, and dismissal ≠ consent.
  group('notice dialog', () {
    Future<bool?> pump(WidgetTester tester,
        {required Future<void> Function(WidgetTester) act}) async {
      bool? result;
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('ar'),
        supportedLocales: const [Locale('ar'), Locale('en')],
        localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () async => result = await showReportAdNotice(context),
              child: const Text('go'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      await act(tester);
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('shows restrained copy with no rewarded language',
        (tester) async {
      await pump(tester, act: (t) async {
        expect(find.text('إعلان قبل إنشاء التقرير'), findsOneWidget);
        expect(find.text('قد يظهر إعلان قصير قبل إنشاء التقرير.'), findsOneWidget);
        expect(find.text('متابعة'), findsOneWidget);
        // No rewarded-ad vocabulary anywhere in the dialog.
        for (final banned in const ['مكافأة', 'شاهد', 'اربح', 'أكمل']) {
          expect(find.textContaining(banned), findsNothing);
        }
        await t.tap(find.text('متابعة'));
      });
    });

    testWidgets('Continue returns true', (tester) async {
      final r = await pump(tester, act: (t) async => t.tap(find.text('متابعة')));
      expect(r, isTrue);
    });

    testWidgets('Cancel returns false (never treated as consent)',
        (tester) async {
      final r = await pump(tester, act: (t) async => t.tap(find.text('إلغاء')));
      expect(r, isFalse);
    });
  });
}
