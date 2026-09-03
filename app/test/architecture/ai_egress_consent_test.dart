import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/privacy/consent_authority.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';

/// AI egress needs BOTH consents. Source contract + policy check.
///
/// ## The defect this exists to prevent
///
/// `ConsentAuthority.decide(EgressClass.aiProcessing)` has always required
/// `cloud && aiConsentGranted` — "OD-07: restrictive state wins". But the
/// production wiring passed `settings.aiConsentGranted` ALONE at four call
/// sites, and `ai_parser_client.dart` never consulted `ConsentAuthority` at
/// all. The two settings switches are independent, so a user with cloud
/// processing OFF and AI ON still had sanitized bank-SMS text transmitted.
///
/// That contradicted the LIVE privacy policy, which promises: "With it off, no
/// financial data leaves your device — this is enforced at every network call,
/// not only in the settings UI." It was a false statement in a published legal
/// document, found on 2026-09-03 while preparing the Play declaration.
///
/// The policy decision was never wrong; the wiring bypassed it. So this pins
/// the wiring, not the decision.

UserSettingsEntity _settings({required bool cloud, required bool ai}) =>
    UserSettingsEntity(
      id: 'settings',
      country: 'SA',
      currency: 'SAR',
      language: 'ar',
      theme: 'dark',
      inputMethod: 'manual',
      notificationsJson: '{}',
      privacyModeEnabled: false,
      cloudConsentState: cloud ? ConsentState.accepted : ConsentState.declined,
      aiConsentState: ai ? ConsentState.accepted : ConsentState.declined,
    );

void main() {
  group('the policy itself', () {
    test('AI requires BOTH cloud and AI consent', () {
      expect(
        ConsentAuthority.decide(
            EgressClass.aiProcessing, _settings(cloud: true, ai: true)),
        isTrue,
      );
      for (final s in [
        _settings(cloud: false, ai: true), // the case that was broken
        _settings(cloud: true, ai: false),
        _settings(cloud: false, ai: false),
      ]) {
        expect(ConsentAuthority.decide(EgressClass.aiProcessing, s), isFalse,
            reason: 'cloud=${s.cloudProcessingEnabled} ai=${s.aiConsentGranted}');
      }
    });

    test('cloud OFF denies for the stated reason', () {
      expect(
        ConsentAuthority.denialReason(
            EgressClass.aiProcessing, _settings(cloud: false, ai: true)),
        'ai_requires_cloud_consent',
      );
    });
  });

  group('the WIRING honours the policy', () {
    // The decision function was always right. What shipped wrong was every
    // caller reading one boolean instead of asking it.
    const wiringFiles = [
      'lib/core/di/app_providers.dart',
      'lib/features/capture/services/captured_message_processor.dart',
    ];

    test('no AI consent site reads aiConsentGranted alone', () {
      for (final path in wiringFiles) {
        final src = File(path).readAsStringSync();
        expect(src.contains('return settings.aiConsentGranted;'), isFalse,
            reason: '$path gates AI on one boolean; it must ask '
                'ConsentAuthority so cloud-off is honoured');
        expect(
          RegExp(r'\)\.aiConsentGranted\b').hasMatch(src),
          isFalse,
          reason: '$path reads aiConsentGranted directly at an egress gate',
        );
      }
    });

    test('every AI consent site routes through ConsentAuthority', () {
      for (final path in wiringFiles) {
        final src = File(path).readAsStringSync();
        if (!src.contains('loadAiConsent') && !src.contains('aiConsent')) {
          continue;
        }
        expect(src, contains('EgressClass.aiProcessing'),
            reason: '$path supplies an AI consent callback but never names '
                'the egress class it is deciding about');
        expect(src, contains('ConsentAuthority.decide'), reason: path);
      }
    });
  });

  test('the privacy policy still makes the promise this enforces', () {
    // If someone weakens the code, this fails and points at the document that
    // would become false — rather than letting the two drift apart silently.
    final policy = File('../docs/legal/PRIVACY_POLICY.md').readAsStringSync();
    expect(policy, contains('no financial data leaves your'),
        reason: 'the promise the wiring above exists to keep');
    // The sentence wraps in the source, so match across the line break.
    final flat = policy.replaceAll(RegExp(r'\s+'), ' ');
    expect(flat, contains('both cloud processing and AI assistance'),
        reason: 'the policy states AI needs BOTH consents');
    expect(flat.contains('reads bank SMS and notification'), isFalse,
        reason: 'Qirsh has no notification-listener capability; claiming one '
            'in a published policy describes a second restricted permission '
            'the app does not request');
  });
}
