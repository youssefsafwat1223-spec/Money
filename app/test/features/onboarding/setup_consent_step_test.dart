import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/features/capture/services/capture_device_registration_service.dart';
import 'package:money_companion/features/onboarding/setup_screen.dart';

import '../consent/consent_test_harness.dart';

void main() {
  late FakeSettingsRepository repo;
  late FakeRegistrationService service;

  Future<void> pumpToConsentStep(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    repo = FakeSettingsRepository();
    service = FakeRegistrationService();
    await tester.pumpWidget(consentApp(
      overrides: [
        ...consentOverrides(repo, service),
        saveCountryCurrencyUseCaseProvider
            .overrideWithValue(_OkSaveCountry()),
      ],
      home: const OnboardingSetupScreen(),
    ));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Step 1 of 4'), findsOneWidget);
    await tester.tap(find.textContaining('Saudi').first);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
  }

  testWidgets('consent step sits between country and notifications',
      (tester) async {
    await pumpToConsentStep(tester);
    expect(find.text('Step 2 of 4'), findsOneWidget);
    expect(find.text('Smart Analysis & Cloud Sync'), findsOneWidget);
    expect(repo.settings.cloudConsentState, ConsentState.unset);
    expect(repo.settings.aiConsentState, ConsentState.unset);

    await tester.tap(find.text('Not now'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text('Step 3 of 4'), findsOneWidget);
    expect(find.text('Turn on notifications'), findsOneWidget);
  });

  testWidgets('Not now leaves consent unchanged', (tester) async {
    await pumpToConsentStep(tester);
    await tester.tap(find.text('Not now'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(repo.saveCalls, 0);
    expect(repo.settings.cloudConsentState, ConsentState.unset);
    expect(repo.settings.aiConsentState, ConsentState.unset);
    expect(service.retryCalls, 0);
  });

  testWidgets('Enable grants both; registration failure does not block Next',
      (tester) async {
    await pumpToConsentStep(tester);
    service.outcome = const CaptureRegistrationStatus(
        CaptureRegistrationPhase.failed, 'register_failed');
    await tester.tap(find.text('Enable Smart Analysis & Cloud Sync'));
    await tester.pumpAndSettle();
    expect(repo.settings.cloudConsentState, ConsentState.accepted);
    expect(repo.settings.aiConsentState, ConsentState.accepted);
    expect(find.textContaining("isn't connected"), findsOneWidget);

    await tester.tap(find.text('Continue'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text('Step 3 of 4'), findsOneWidget);
  });
}

class _OkSaveCountry extends FakeSaveCountry {
  @override
  Future<UserSettingsEntity> call(String country, String currency) async =>
      FakeSettingsRepository().settings;
}
