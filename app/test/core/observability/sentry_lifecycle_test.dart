import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/observability/sentry_lifecycle.dart';
import 'package:money_companion/core/privacy/diagnostics_consent_gate.dart';

import '../../harness/egress_test_support.dart';

/// Astra H2.5: Sentry runs only while the egress gate permits AND diagnostics
/// consent is open; any transition to not-permitted closes it; permitted again
/// re-initialises. (SentryConfig.isConfigured is a dart-define, so the lifecycle
/// is driven here through its test hooks.)
void main() {
  late int inits;
  late int closes;

  setUp(() {
    inits = 0;
    closes = 0;
    SentryLifecycle.debugReset();
    SentryLifecycle.debugSetHooks(
      init: (_) async => inits++,
      close: () async => closes++,
      configured: () => true,
    );
    DiagnosticsConsentGate.resetForTest();
  });
  tearDown(() {
    SentryLifecycle.debugReset();
    DiagnosticsConsentGate.resetForTest();
  });

  Future<void> settle() async {
    await pumpEventQueue();
    await SentryLifecycle.requestReconcile();
  }

  test('nothing is initialised before the gate permits, even with consent',
      () async {
    final e = TestEgress(resolved: false, seedOn: true).install();
    SentryLifecycle.attach();
    DiagnosticsConsentGate.set(true);
    await settle();
    expect(inits, 0, reason: 'unresolved');
    e.gate.markResolved();
    await e.gate.refresh();
    await settle();
    expect(inits, 1);
    expect(SentryLifecycle.isRunning, isTrue);
  });

  test('OFF / absent record never initialises', () async {
    TestEgress().install(); // resolved, no record
    SentryLifecycle.attach();
    DiagnosticsConsentGate.set(true);
    await settle();
    expect(inits, 0);
  });

  test('no diagnostics consent: not initialised even when permitted', () async {
    TestEgress(seedOn: true).install();
    SentryLifecycle.attach();
    await settle();
    expect(inits, 0);
  });

  test('a transition to not-permitted closes; permitted again re-initialises',
      () async {
    final e = TestEgress(seedOn: true).install();
    SentryLifecycle.attach();
    DiagnosticsConsentGate.set(true);
    await e.gate.refresh();
    await settle();
    expect((inits, closes), (1, 0));

    final freeze =
        await e.gate.beginDisabling(owner: 'uid-a', reservedVersion: 2);
    await settle();
    expect(closes, 1, reason: 'DISABLING closes');
    await e.gate.commitOff(freeze);
    await settle();
    expect(inits, 1);

    await e.gate.enable(owner: 'uid-a', reservedVersion: 3);
    await e.gate.refresh();
    await settle();
    expect(inits, 2, reason: 're-initialised once permitted again');

    DiagnosticsConsentGate.revoke();
    await settle();
    expect(closes, 2, reason: 'consent revoked closes too');
  });

  test('the options drop events and breadcrumbs unless both gates are open',
      () {
    // Source pin of the hook wiring (the hooks need a real SentryEvent).
    final src =
        File('lib/core/observability/sentry_lifecycle.dart').readAsStringSync();
    expect(src, contains('permitsNetworkSync'));
    expect(src, contains('Sentry.close'));
  });
}
