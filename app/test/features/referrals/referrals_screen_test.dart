import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/features/common/app_error_state.dart';
import 'package:money_companion/features/common/app_loading_state.dart';
import 'package:money_companion/features/referrals/referral_models.dart';
import 'package:money_companion/features/referrals/referrals_providers.dart';
import 'package:money_companion/features/referrals/referrals_screen.dart';
import 'package:money_companion/features/referrals/services/referral_service.dart';
import 'package:money_companion/l10n/app_localizations.dart';

/// A fake ReferralService — the widget layer is exercised without any live
/// Supabase, faked at the service/provider boundary (the app's test idiom).
class _FakeReferralService implements ReferralService {
  _FakeReferralService({
    this.summary,
    this.applyOutcome = const ApplyCodeOutcome(ok: true),
    this.throwOnSummary = false,
    this.hangSummary = false,
  });

  ReferralSummary? summary;
  ApplyCodeOutcome applyOutcome;
  bool throwOnSummary;
  bool hangSummary;

  int summaryCalls = 0;
  String? appliedCode;

  @override
  Future<ReferralSummary?> getSummary() async {
    summaryCalls++;
    if (hangSummary) return Completer<ReferralSummary?>().future; // never resolves
    if (throwOnSummary) throw const ServerRepoExceptionStub();
    return summary;
  }

  @override
  Future<ApplyCodeOutcome> applyCode(String code) async {
    appliedCode = code;
    return applyOutcome;
  }

  @override
  Future<QualificationOutcome> requestQualification() async =>
      const QualificationOutcome(qualified: false, granted: false);

  @override
  Future<EntitlementDecision?> getEntitlementDecision() async => null;
}

class ServerRepoExceptionStub implements Exception {
  const ServerRepoExceptionStub();
}

ReferralSummary _summary({
  AttributionStatus attribution = AttributionStatus.none,
  String entitlementStatus = 'none',
  DateTime? endsAt,
}) {
  return ReferralSummary(
    referralCode: 'QK7F9X2M',
    progress: 3,
    requiredReferrals: 5,
    rewardDays: 7,
    repeatable: true,
    cycleIndex: 1,
    cycleState: 'open',
    referralsAvailable: true,
    attributionStatus: attribution,
    entitlementStatus: entitlementStatus,
    entitlementEndsAt: endsAt,
    serverNow: DateTime.utc(2026, 8, 17),
  );
}

Widget _app(Widget child, {required List<Override> overrides, Locale locale = const Locale('ar')}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      locale: locale,
      localizationsDelegates: const [
        AppL10n.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppL10n.supportedLocales,
      theme: AppTheme.dark,
      home: child,
    ),
  );
}

Widget _screen() => const ReferralsScreen();

void main() {
  testWidgets('feature flag OFF hides referral functionality (unavailable state)',
      (tester) async {
    await tester.pumpWidget(_app(
      _screen(),
      overrides: [
        referralsEnabledProvider.overrideWithValue(false),
        referralServiceProvider.overrideWithValue(_FakeReferralService(summary: _summary())),
      ],
    ));
    await tester.pump();
    expect(find.text('الدعوات غير متاحة حاليًا'), findsOneWidget);
    // No active referral functionality: the code is not shown.
    expect(find.text('QK7F9X2M'), findsNothing);
  });

  testWidgets('summary success renders code, progress and reward (report-export scope)',
      (tester) async {
    await tester.pumpWidget(_app(
      _screen(),
      overrides: [
        referralsEnabledProvider.overrideWithValue(true),
        referralServiceProvider.overrideWithValue(_FakeReferralService(summary: _summary())),
      ],
    ));
    await tester.pump();
    expect(find.text('QK7F9X2M'), findsOneWidget);
    expect(find.text('3 / 5 دعوات صالحة'), findsOneWidget);
    expect(find.text('تقارير بدون إعلانات لمدة 7 يومًا'), findsOneWidget);
    // §5: reward scope is report-export ads only, made explicit in the UI.
    expect(find.textContaining('تصدير التقارير'), findsOneWidget);
  });

  testWidgets('loading state renders while the summary is in flight', (tester) async {
    await tester.pumpWidget(_app(
      _screen(),
      overrides: [
        referralsEnabledProvider.overrideWithValue(true),
        referralServiceProvider
            .overrideWithValue(_FakeReferralService(hangSummary: true)),
      ],
    ));
    await tester.pump();
    expect(find.byType(AppLoadingState), findsOneWidget);
  });

  testWidgets('error state renders with a retry action on summary failure',
      (tester) async {
    await tester.pumpWidget(_app(
      _screen(),
      overrides: [
        referralsEnabledProvider.overrideWithValue(true),
        referralServiceProvider
            .overrideWithValue(_FakeReferralService(throwOnSummary: true)),
      ],
    ));
    await tester.pump();
    expect(find.byType(AppErrorState), findsOneWidget);
    expect(find.text('إعادة المحاولة'), findsOneWidget);
  });

  testWidgets('applying a valid code calls the RPC and refetches the summary',
      (tester) async {
    tester.view.physicalSize = const Size(400, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fake = _FakeReferralService(
      summary: _summary(attribution: AttributionStatus.none),
      applyOutcome: const ApplyCodeOutcome(ok: true),
    );
    await tester.pumpWidget(_app(
      _screen(),
      overrides: [
        referralsEnabledProvider.overrideWithValue(true),
        referralServiceProvider.overrideWithValue(fake),
      ],
    ));
    await tester.pump();
    expect(fake.summaryCalls, 1);

    await tester.enterText(find.byType(TextField), 'qk7f9x2m');
    await tester.tap(find.text('تفعيل الرمز'));
    await tester.pump(); // run applyCode
    await tester.pump(); // process invalidate → refetch

    expect(fake.appliedCode, 'qk7f9x2m');
    expect(fake.summaryCalls, greaterThanOrEqualTo(2));
    await tester.pump(const Duration(seconds: 5)); // flush the toast auto-dismiss timer
  });

  testWidgets('server rejection surfaces controlled copy, not a raw token',
      (tester) async {
    tester.view.physicalSize = const Size(400, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fake = _FakeReferralService(
      summary: _summary(attribution: AttributionStatus.none),
      applyOutcome: const ApplyCodeOutcome(ok: false, reason: ReferralReason.selfReferral),
    );
    await tester.pumpWidget(_app(
      _screen(),
      overrides: [
        referralsEnabledProvider.overrideWithValue(true),
        referralServiceProvider.overrideWithValue(fake),
      ],
    ));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'MYCODE12');
    await tester.tap(find.text('تفعيل الرمز'));
    await tester.pump();
    // The mapped Arabic message appears; the raw token never does.
    expect(find.text('لا يمكنك استخدام رمزك الخاص.'), findsOneWidget);
    expect(find.textContaining('self_referral'), findsNothing);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('an already-attributed user sees the applied note, not the apply field',
      (tester) async {
    await tester.pumpWidget(_app(
      _screen(),
      overrides: [
        referralsEnabledProvider.overrideWithValue(true),
        referralServiceProvider.overrideWithValue(
          _FakeReferralService(summary: _summary(attribution: AttributionStatus.qualified)),
        ),
      ],
    ));
    await tester.pump();
    expect(find.byType(TextField), findsNothing);
    expect(find.text('تم تفعيل رمز دعوة على حسابك.'), findsOneWidget);
  });

  testWidgets('active entitlement shows the ad-free-until line', (tester) async {
    await tester.pumpWidget(_app(
      _screen(),
      overrides: [
        referralsEnabledProvider.overrideWithValue(true),
        referralServiceProvider.overrideWithValue(_FakeReferralService(
          summary: _summary(
            entitlementStatus: 'active',
            endsAt: DateTime.utc(2026, 8, 24),
          ),
        )),
      ],
    ));
    await tester.pump();
    expect(find.textContaining('تقارير بدون إعلانات حتى'), findsOneWidget);
  });

  testWidgets('layout is RTL under the Arabic locale', (tester) async {
    await tester.pumpWidget(_app(
      _screen(),
      overrides: [
        referralsEnabledProvider.overrideWithValue(true),
        referralServiceProvider.overrideWithValue(_FakeReferralService(summary: _summary())),
      ],
    ));
    await tester.pump();
    expect(Directionality.of(tester.element(find.text('QK7F9X2M'))), TextDirection.rtl);
  });

  testWidgets('renders without overflow on a small screen', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_app(
      _screen(),
      overrides: [
        referralsEnabledProvider.overrideWithValue(true),
        referralServiceProvider.overrideWithValue(_FakeReferralService(
          summary: _summary(entitlementStatus: 'active', endsAt: DateTime.utc(2026, 8, 24)),
        )),
      ],
    ));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
