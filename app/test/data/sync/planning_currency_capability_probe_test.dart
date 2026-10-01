import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/sync/sync_health.dart';
import 'package:money_companion/data/sync/exact_transport_capability.dart';
import 'package:money_companion/data/sync/planning_currency_capability_probe.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _verified = ExactTransportCapability.verifiedExact;
const _unsupported = ExactTransportCapability.unsupported;
const _unknown = ExactTransportCapability.unknown;

class _Harness {
  _Harness() {
    probe = PlanningCurrencyCapabilityProbe(
      getAuthUserId: () async => uid,
      probeCurrencyColumn: (table) async {
        calls.add(table);
        final outcome = outcomes[table];
        if (outcome != null) throw outcome;
      },
      onChanged: published.add,
      mayEgress: () async => consent,
      health: health,
      getServerUrl: () => 'https://server.test',
      clock: () => now,
    );
  }

  String? uid = 'u1';
  bool consent = true;
  DateTime now = DateTime.utc(2026, 1, 1);
  final Map<String, Object> outcomes = {};
  final List<String> calls = [];
  final List<ExactTransportCapability> published = [];
  final SyncHealth health = SyncHealth();
  late final PlanningCurrencyCapabilityProbe probe;
}

PostgrestException _pg(String code, [String message = 'm']) =>
    PostgrestException(message: message, code: code);

void main() {
  test('both tables probed independently; success => verifiedExact', () async {
    final h = _Harness();
    expect(await h.probe.ensure(), _verified);
    expect(h.calls, ['user_budgets', 'user_goals']);
    expect(h.published.last, _verified);
    expect(h.health.capabilityStates['planning currency (user_budgets)'],
        'verifiedExact');
    expect(h.health.capabilityStates['planning currency'], 'verifiedExact');
  });

  test('undefined column on ONE table => unsupported (weaker of the two)',
      () async {
    for (final code in ['42703', 'PGRST204', 'PGRST200', '42P01', 'PGRST205']) {
      final h = _Harness()..outcomes['user_goals'] = _pg(code);
      expect(await h.probe.ensure(), _unsupported, reason: code);
      expect(h.calls, ['user_budgets', 'user_goals'],
          reason: 'budgets is still probed independently ($code)');
      expect(h.health.capabilityStates['planning currency (user_budgets)'],
          'verifiedExact');
      expect(h.health.capabilityStates['planning currency (user_goals)'],
          'unsupported');
    }
  });

  test('network / auth / 5xx / ambiguous errors stay unknown, never unsupported',
      () async {
    final errors = <Object>[
      const SocketException('offline'),
      TimeoutException('slow'),
      const AuthException('jwt expired'),
      _pg('PGRST303', 'JWT expired'),
      _pg('401'),
      _pg('500'),
      _pg('PGRST000'),
      StateError('weird'),
    ];
    for (final e in errors) {
      final h = _Harness()..outcomes['user_budgets'] = e;
      expect(await h.probe.ensure(), _unknown, reason: '$e');
      expect(h.published.last, _unknown);
    }
  });

  test('unknown is re-probed only after the back-off; verified is cached',
      () async {
    final h = _Harness()..outcomes['user_budgets'] = const SocketException('x');
    expect(await h.probe.ensure(), _unknown);
    h.calls.clear();

    await h.probe.ensure();
    expect(h.calls, isEmpty, reason: 'throttled inside the back-off');

    h.now = h.now.add(const Duration(minutes: 3));
    h.outcomes.clear();
    expect(await h.probe.ensure(), _verified);
    expect(h.calls, ['user_budgets'],
        reason: 'only the table whose answer was unknown is re-probed');

    h.calls.clear();
    await h.probe.ensure();
    expect(h.calls, isEmpty, reason: 'verified is cached for the session');
  });

  test('consent is fail-closed and asked fresh: no consent => no request',
      () async {
    final h = _Harness()..consent = false;
    expect(await h.probe.ensure(), _unknown);
    expect(h.calls, isEmpty);
    h.consent = true;
    h.now = h.now.add(const Duration(minutes: 3));
    expect(await h.probe.ensure(), _verified);
    expect(h.calls, isNotEmpty);
  });

  test('signed out => no request, unknown published', () async {
    final h = _Harness()..uid = null;
    expect(await h.probe.ensure(), _unknown);
    expect(h.calls, isEmpty);
    expect(h.published.last, _unknown);
  });

  test('resume re-probe is throttled and picks up a server upgrade', () async {
    final h = _Harness()..outcomes['user_goals'] = _pg('42703');
    expect(await h.probe.ensure(), _unsupported);
    h.calls.clear();

    // 0077 deployed meanwhile.
    h.outcomes.clear();
    h.now = h.now.add(const Duration(minutes: 5));
    expect(await h.probe.reprobeIfStale(), _unsupported,
        reason: 'inside the 15 minute throttle');
    expect(h.calls, isEmpty);

    h.now = h.now.add(const Duration(minutes: 11));
    expect(await h.probe.reprobeIfStale(), _verified);
    expect(h.calls, ['user_goals'], reason: 'verified budgets is not re-probed');

    h.calls.clear();
    h.now = h.now.add(const Duration(hours: 1));
    await h.probe.reprobeIfStale();
    expect(h.calls, isEmpty, reason: 'verified is never re-probed');
  });

  test('force (Retry) re-probes unknown/unsupported immediately', () async {
    final h = _Harness()..outcomes['user_goals'] = _pg('42703');
    await h.probe.ensure();
    h.calls.clear();
    h.outcomes.clear();
    expect(await h.probe.ensure(force: true), _verified);
    expect(h.calls, ['user_goals']);
  });

  test('a different user never inherits the previous verified answer', () async {
    final h = _Harness();
    expect(await h.probe.ensure(), _verified);
    h.uid = 'u2';
    h.consent = false; // probe cannot run for u2
    expect(await h.probe.ensure(), _unknown);
    expect(h.published.last, _unknown);
  });

  test('wired to the Notifier: every update is visible to call-time readers',
      () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final probe = PlanningCurrencyCapabilityProbe(
      getAuthUserId: () async => 'u1',
      probeCurrencyColumn: (_) async {},
      onChanged: (c) =>
          container.read(planningServerCurrencyCapabilityProvider.notifier).set(c),
      mayEgress: () async => true,
    );
    bool gate() => planningMoneyEntitySyncEnabled(
          isPlanningCurrencyGatedEntity: true,
          planningCurrencyCapability:
              container.read(planningServerCurrencyCapabilityProvider),
          transportCapability: _verified,
        );
    expect(container.read(planningServerCurrencyCapabilityProvider), _unknown);
    expect(gate(), isFalse);
    await probe.ensure();
    expect(container.read(planningServerCurrencyCapabilityProvider), _verified);
    expect(gate(), isTrue);
  });
}
