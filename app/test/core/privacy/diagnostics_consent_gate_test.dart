import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/privacy/consent_authority.dart';
import 'package:money_companion/core/privacy/diagnostics_consent_gate.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';

/// OD-05 / C-3 — crash reporting must not egress without cloud consent.
///
/// Sentry was armed on DSN presence alone (`main.dart`), so crash and breadcrumb
/// payloads — which carry device, build and context information — left the
/// device regardless of the privacy switch.
///
/// The SDK still initialises (early-startup crashes are the most valuable ones,
/// and consent cannot be read before the encrypted DB is open), but every
/// payload now passes this gate first.
UserSettingsEntity _settings(ConsentState cloud) => UserSettingsEntity(
      id: 'settings',
      country: 'SA',
      currency: 'SAR',
      language: 'ar',
      theme: 'dark',
      inputMethod: 'manual',
      notificationsJson: '{}',
      privacyModeEnabled: false,
      cloudConsentState: cloud,
    );

void main() {
  setUp(DiagnosticsConsentGate.resetForTest);

  test('defaults to DENY — the window before settings load cannot leak', () {
    // Process start → first successful settings read is a real window, and a
    // crash inside bootstrap lands squarely in it.
    expect(DiagnosticsConsentGate.allowed, isFalse);
  });

  test('opens only for an explicit cloud-consent grant', () {
    DiagnosticsConsentGate.set(
      ConsentAuthority.decide(
          EgressClass.diagnostics, _settings(ConsentState.accepted)),
    );
    expect(DiagnosticsConsentGate.allowed, isTrue);
  });

  test('stays shut for unset and for declined', () {
    for (final state in [ConsentState.unset, ConsentState.declined]) {
      DiagnosticsConsentGate.set(
        ConsentAuthority.decide(EgressClass.diagnostics, _settings(state)),
      );
      expect(DiagnosticsConsentGate.allowed, isFalse, reason: '$state');
    }
  });

  test('revocation shuts the gate immediately, not at next startup', () {
    DiagnosticsConsentGate.set(true);
    expect(DiagnosticsConsentGate.allowed, isTrue);

    // What the privacy screen does the moment the switch flips off.
    DiagnosticsConsentGate.set(
      ConsentAuthority.decide(
          EgressClass.diagnostics, _settings(ConsentState.declined)),
    );
    expect(DiagnosticsConsentGate.allowed, isFalse,
        reason: 'a revocation must take effect before the NEXT crash, and '
            'beforeSend is synchronous so it cannot await a settings read');
  });

  test('revoke() is an unconditional close', () {
    DiagnosticsConsentGate.set(true);
    DiagnosticsConsentGate.revoke();
    expect(DiagnosticsConsentGate.allowed, isFalse);
  });

  test('main.dart consults the gate BEFORE sanitising', () {
    // Sanitising decides what a payload may contain; it never decides whether
    // the payload may exist. If the gate were applied after (or not at all), an
    // unconsented but well-sanitised crash would still egress.
    final main = _read('lib/main.dart');
    expect(main, contains('DiagnosticsConsentGate.allowed'));
    for (final hook in ['beforeSend', 'beforeBreadcrumb']) {
      final idx = main.indexOf('options.$hook');
      expect(idx, greaterThan(-1), reason: '$hook must be configured');
      final body = main.substring(idx, idx + 260);
      expect(body, contains('DiagnosticsConsentGate.allowed'),
          reason: '$hook must be consent-gated, not only sanitised');
    }
  });
}

String _read(String relative) => File(relative).readAsStringSync();
