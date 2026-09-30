import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/features/coupons/coupons_providers.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/features/capture/services/capture_device_registration_service.dart';
import 'package:money_companion/features/settings/privacy_screen.dart';

import '../consent/consent_test_harness.dart';

void main() {
  testWidgets('failed status row shows on Privacy and Retry calls retry()',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final repo = FakeSettingsRepository();
    repo.settings = repo.settings.copyWith(
      cloudConsentState: ConsentState.accepted,
      aiConsentState: ConsentState.accepted,
    );
    final service = FakeRegistrationService(
        outcome: const CaptureRegistrationStatus(
            CaptureRegistrationPhase.connected));
    service.notifier.value = const CaptureRegistrationStatus(
        CaptureRegistrationPhase.failed, 'register_failed');
    await tester.pumpWidget(consentApp(
      overrides: [
        ...consentOverrides(repo, service),
        merchantOffersEnabledProvider.overrideWithValue(false),
      ],
      home: const PrivacyScreen(),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining("isn't connected"), findsOneWidget);
    await tester.ensureVisible(find.text('Retry'));
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(service.retryCalls, 1);
    expect(find.text('Smart Analysis is connected'), findsOneWidget);
  });

  testWidgets('no status row while cloud consent is off', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final repo = FakeSettingsRepository();
    final service = FakeRegistrationService();
    service.notifier.value = const CaptureRegistrationStatus(
        CaptureRegistrationPhase.failed, 'register_failed');
    await tester.pumpWidget(consentApp(
      overrides: [
        ...consentOverrides(repo, service),
        merchantOffersEnabledProvider.overrideWithValue(false),
      ],
      home: const PrivacyScreen(),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining("isn't connected"), findsNothing);
  });
}
