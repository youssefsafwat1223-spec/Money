import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/core/sync/outbox_failure.dart';
import 'package:money_companion/data/sync/server_capabilities.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  var advertised = false; // what the server says
  var calls = 0;
  var now = DateTime.utc(2026, 6, 1, 10);
  var consent = true;

  SupabaseClient client() => SupabaseClient(
        'https://example.supabase.co',
        'anon',
        accessToken: () async => 'tok',
        httpClient: MockClient((request) async {
          calls++;
          return http.Response(
              jsonEncode({'awaiting_fx_transactions': advertised}), 200,
              headers: const {'content-type': 'application/json'},
              request: request);
        }),
      );

  ServerCapabilitiesService svc() => ServerCapabilitiesService(
        getAuthUserId: () async => 'u1',
        getClient: client,
        mayEgress: () async => consent,
        getServerUrl: () => 'https://example.supabase.co',
        clock: () => now,
      );

  setUp(() {
    advertised = false;
    calls = 0;
    now = DateTime.utc(2026, 6, 1, 10);
    consent = true;
  });

  test('cached unsupported is re-probed on resume, throttled to 15 minutes',
      () async {
    final s = svc();
    expect(await s.awaitingFxTransactions(), ServerCapabilityState.unsupported);
    expect(calls, 1);
    // Cached for the session: a normal read never re-probes.
    expect(await s.awaitingFxTransactions(), ServerCapabilityState.unsupported);
    expect(calls, 1);

    // Server deploys 0102 while the app keeps running.
    advertised = true;
    now = now.add(const Duration(minutes: 5));
    expect(await s.reprobeIfStale(), ServerCapabilityState.unsupported,
        reason: 'throttled: probed 5 minutes ago');
    expect(calls, 1);

    now = now.add(const Duration(minutes: 11));
    expect(await s.reprobeIfStale(), ServerCapabilityState.verified);
    expect(calls, 2);
    expect(s.cachedAwaitingFx('u1'), ServerCapabilityState.verified);

    // Verified is final for the session — never re-probed.
    now = now.add(const Duration(hours: 2));
    expect(await s.reprobeIfStale(), ServerCapabilityState.verified);
    expect(calls, 2);
  });

  test('Retry (force) bypasses the throttle', () async {
    final s = svc();
    await s.awaitingFxTransactions();
    advertised = true;
    expect(await s.awaitingFxTransactions(force: true),
        ServerCapabilityState.verified);
    expect(calls, 2);
  });

  test('resume re-probe is consent-gated: nothing is sent with consent off',
      () async {
    consent = false;
    final s = svc();
    expect(await s.reprobeIfStale(), ServerCapabilityState.unknown);
    expect(calls, 0);
  });

  test('PostgREST JWT error shapes classify as auth (no attempt consumed)', () {
    for (final code in ['PGRST301', 'PGRST302', 'PGRST303', '401', '403', '42501']) {
      expect(
          classifyOutboxError(
              PostgrestException(message: 'JWT expired', code: code)),
          OutboxFailureClass.auth,
          reason: code);
    }
  });
}
