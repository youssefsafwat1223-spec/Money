import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/features/common/app_error_state.dart';
import 'package:money_companion/features/referrals/referral_error.dart';
import 'package:money_companion/features/referrals/referral_models.dart';
import 'package:money_companion/features/referrals/referrals_providers.dart';
import 'package:money_companion/features/referrals/referrals_screen.dart';
import 'package:money_companion/features/referrals/services/referral_service.dart';
import 'package:money_companion/l10n/app_localizations.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// D6: the old referral protocol is permanently retired (QD040 feature_retired).

const _retired = PostgrestException(
    message: 'feature_retired', code: 'QD040', details: null, hint: null);

class _Service implements ReferralService {
  _Service({this.summary, this.summaryError, this.applyError, this.applyOutcome});
  final ReferralSummary? summary;
  final Object? summaryError;
  final Object? applyError;
  final ApplyCodeOutcome? applyOutcome;
  @override
  Future<ReferralSummary?> getSummary() async {
    if (summaryError != null) throw summaryError!;
    return summary;
  }

  @override
  Future<ApplyCodeOutcome> applyCode(String code) async {
    if (applyError != null) throw applyError!;
    return applyOutcome!;
  }

  @override
  Future<QualificationOutcome> requestQualification() async =>
      const QualificationOutcome(qualified: false, granted: false);
  @override
  Future<EntitlementDecision?> getEntitlementDecision() async => null;
}

Widget _app(List<Override> overrides) => ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: const [
          AppL10n.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppL10n.supportedLocales,
        theme: AppTheme.dark,
        home: const ReferralsScreen(),
      ),
    );

ReferralSummary _summary() => ReferralSummary(
      referralCode: 'QK7F9X2M',
      progress: 0,
      requiredReferrals: 5,
      rewardDays: 7,
      repeatable: true,
      cycleIndex: 1,
      cycleState: 'open',
      referralsAvailable: true,
      attributionStatus: AttributionStatus.none,
      entitlementStatus: 'none',
      entitlementEndsAt: null,
      serverNow: DateTime.utc(2026, 8, 17),
    );

void main() {
  final en = lookupAppL10n(const Locale('en'));

  test('Beta 1 hides every referral entry point regardless of any flag', () {
    expect(kReferralsRetired, isTrue);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(referralsEnabledProvider), isFalse);
  });

  test('QD040 / feature_retired is recognised; other errors are not', () {
    expect(isReferralFeatureRetired(_retired), isTrue);
    expect(
        isReferralFeatureRetired(const PostgrestException(
            message: 'x', code: 'P0001', details: null, hint: 'feature_retired')),
        isTrue);
    expect(
        isReferralFeatureRetired(const PostgrestException(
            message: 'boom', code: 'XX000', details: null, hint: null)),
        isFalse);
    expect(isReferralFeatureRetired(StateError('QD040')), isFalse);
  });

  test('the service turns a retired refusal into a soft outcome, not a throw',
      () async {
    final client = SupabaseClient('https://example.supabase.co', 'anon',
        httpClient: MockClient((request) async => http.Response(
            jsonEncode({
              'code': 'QD040',
              'message': 'feature_retired',
              'details': null,
              'hint': null
            }),
            400,
            request: request,
            headers: {'content-type': 'application/json'})));
    addTearDown(client.dispose);
    final service = SupabaseReferralService(getClient: () => client);
    final outcome = await service.requestQualification();
    expect(outcome.qualified, isFalse);
    expect(outcome.reason, ReferralReason.featureRetired);
  });

  testWidgets('a retired summary shows the neutral unavailable state, not an error',
      (tester) async {
    await tester.pumpWidget(_app([
      referralsEnabledProvider.overrideWithValue(true),
      referralServiceProvider
          .overrideWithValue(_Service(summaryError: _retired)),
    ]));
    await tester.pump();
    await tester.pump();
    expect(find.text(en.referralUnavailableTitle), findsOneWidget);
    expect(find.byType(AppErrorState), findsNothing);
    expect(find.text(en.referralRetry), findsNothing);
  });

  test('the summary provider maps a retired refusal to "unavailable" (null)',
      () async {
    final container = ProviderContainer(overrides: [
      referralsEnabledProvider.overrideWithValue(true),
      referralServiceProvider
          .overrideWithValue(_Service(summaryError: _retired)),
    ]);
    addTearDown(container.dispose);
    expect(await container.read(referralSummaryProvider.future), isNull);
  });

  test('retired refusals map to the neutral "not available right now" copy', () {
    expect(referralThrownMessage(en, _retired), en.referralErrorNoActiveRule);
    expect(referralReasonMessage(en, ReferralReason.featureRetired),
        en.referralErrorNoActiveRule);
    expect(en.referralErrorNoActiveRule, "Invites aren't available right now.");
  });

  for (final c in [
    (
      'a soft feature_retired outcome',
      _Service(
          summary: _summary(),
          applyOutcome: const ApplyCodeOutcome(
              ok: false, reason: ReferralReason.featureRetired))
    ),
    (
      'a thrown QD040',
      _Service(summary: _summary(), applyError: _retired)
    ),
  ]) {
    testWidgets('applying a code with ${c.$1} shows neutral copy, no raw token',
        (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(_app([
        referralsEnabledProvider.overrideWithValue(true),
        referralServiceProvider.overrideWithValue(c.$2),
      ]));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'MYCODE12');
      await tester.tap(find.text(en.referralApplyAction));
      await tester.pump();
      expect(find.text(en.referralErrorNoActiveRule), findsOneWidget);
      expect(find.textContaining('QD040'), findsNothing);
      expect(find.textContaining('feature_retired'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 5));
    });
  }
}
