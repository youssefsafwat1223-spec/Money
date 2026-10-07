import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/features/capture/services/capture_device_registration_service.dart';
import 'package:money_companion/features/consent/smart_analysis_consent_sheet.dart';

import 'consent_test_harness.dart';

class _Opener extends ConsumerWidget {
  const _Opener(this.onResult);
  final ValueChanged<bool> onResult;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () async =>
                onResult(await showSmartAnalysisConsentSheet(context, ref)),
            child: const Text('open'),
          ),
        ),
      );
}

void main() {
  late FakeSettingsRepository repo;
  late FakeRegistrationService service;
  bool? result;

  Future<void> open(WidgetTester tester,
      {String locale = 'en', bool cloudOn = false}) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    repo = FakeSettingsRepository();
    if (cloudOn) {
      repo.settings =
          repo.settings.copyWith(cloudConsentState: ConsentState.accepted);
    }
    service = FakeRegistrationService();
    result = null;
    await tester.pumpWidget(consentApp(
      overrides: consentOverrides(repo, service),
      home: _Opener((v) => result = v),
      locale: locale,
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  void expectUntouched() {
    expect(repo.saveCalls, 0);
    expect(repo.settings.cloudConsentState, ConsentState.unset);
    expect(repo.settings.aiConsentState, ConsentState.unset);
    expect(service.retryCalls, 0);
  }

  testWidgets('two separate controls, nothing pre-selected (EN)',
      (tester) async {
    await open(tester);
    expectUntouched();
    expect(find.byType(Checkbox), findsNothing);
    expect(find.byType(Switch), findsNothing);
    expect(find.text('Smart Analysis & Cloud Sync'), findsOneWidget);
    expect(find.text('Cloud Sync'), findsOneWidget);
    expect(find.text('Smart Analysis'), findsOneWidget);
    expect(find.textContaining('analysed by an AI service'), findsOneWidget);
    expect(find.textContaining('synced and backed up'), findsOneWidget);
    expect(find.text('Enable Cloud Sync'), findsOneWidget);
    // AI needs cloud: no AI control until cloud is on, and no combined action.
    expect(find.text('Enable Smart Analysis'), findsNothing);
    expect(find.text('Enable Smart Analysis & Cloud Sync'), findsNothing);
    expect(find.text('Turn on Cloud Sync first to use Smart Analysis.'),
        findsOneWidget);
    expect(find.text('Not now'), findsOneWidget);
    expect(find.text('Privacy settings'), findsOneWidget);
  });

  testWidgets('two separate controls (AR)', (tester) async {
    await open(tester, locale: 'ar');
    expect(find.text('التحليل الذكي والمزامنة السحابية'), findsOneWidget);
    expect(find.text('تفعيل المزامنة السحابية'), findsOneWidget);
    expect(find.text('تفعيل التحليل الذكي'), findsNothing);
    expect(find.text('فعّل المزامنة السحابية أولاً لاستخدام التحليل الذكي.'),
        findsOneWidget);
    expect(find.text('ليس الآن'), findsOneWidget);
  });

  testWidgets('Enable Cloud Sync grants ONLY cloud; AI stays unset and its '
      'control appears afterwards', (tester) async {
    await open(tester);
    await tester.tap(find.text('Enable Cloud Sync'));
    await tester.pumpAndSettle();
    expect(repo.settings.cloudConsentState, ConsentState.accepted);
    expect(repo.settings.aiConsentState, ConsentState.unset);
    expect(service.syncCalls, 1);
    expect(service.retryCalls, 0, reason: 'no AI registration without AI consent');
    expect(find.text('Enable Smart Analysis'), findsOneWidget);
    expect(result, isNull);
  });

  testWidgets('Smart Analysis is its own action, after cloud, and returns true',
      (tester) async {
    await open(tester);
    await tester.tap(find.text('Enable Cloud Sync'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enable Smart Analysis'));
    await tester.pumpAndSettle();
    expect(repo.settings.cloudConsentState, ConsentState.accepted);
    expect(repo.settings.aiConsentState, ConsentState.accepted);
    expect(service.retryCalls, 1);
    expect(find.text('Smart Analysis is connected'), findsOneWidget);
    expect(result, isNull, reason: 'sheet stays open to show live status');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });

  testWidgets('with cloud already on, only the AI control is offered',
      (tester) async {
    await open(tester, cloudOn: true);
    expect(find.text('Enable Cloud Sync'), findsNothing);
    await tester.tap(find.text('Enable Smart Analysis'));
    await tester.pumpAndSettle();
    expect(repo.settings.aiConsentState, ConsentState.accepted);
    expect(service.retryCalls, 1);
  });

  testWidgets('failed status shows message and Retry re-runs sync',
      (tester) async {
    await open(tester);
    service.outcome = const CaptureRegistrationStatus(
        CaptureRegistrationPhase.failed, 'register_failed');
    await tester.tap(find.text('Enable Cloud Sync'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enable Smart Analysis'));
    await tester.pumpAndSettle();
    expect(find.textContaining("isn't connected"), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(service.retryCalls, 2);
  });

  testWidgets('save failure shows an error and leaves consent ungranted',
      (tester) async {
    await open(tester);
    repo.failSave = true;
    await tester.tap(find.text('Enable Cloud Sync'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('could not be saved'), findsOneWidget);
    expect(repo.settings.cloudConsentState, ConsentState.unset);
    expect(repo.settings.aiConsentState, ConsentState.unset);
    expect(service.retryCalls, 0);
    expect(find.text('Enable Cloud Sync'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 6));
  });

  testWidgets('Not now changes nothing and returns false', (tester) async {
    await open(tester);
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expectUntouched();
    expect(result, isFalse);
  });

  testWidgets('dismissing the sheet changes nothing and returns false',
      (tester) async {
    await open(tester);
    await tester.tapAt(const Offset(10, 10)); // barrier
    await tester.pumpAndSettle();
    expectUntouched();
    expect(result, isFalse);
  });
}
