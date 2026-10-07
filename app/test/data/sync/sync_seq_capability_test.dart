// WP-4: the sync_seq capability probe (kill switch semantics).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/data/sync/server_capabilities.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  late DateTime now;
  late int calls;
  late http.Response Function(http.Request) reply;

  ServerCapabilitiesService svc() => ServerCapabilitiesService(
        getAuthUserId: () async => 'u1',
        getClient: () => SupabaseClient(
          'https://example.supabase.co',
          'anon',
          accessToken: () async => 't',
          httpClient: MockClient((r) async {
            calls++;
            return reply(r);
          }),
        ),
        mayEgress: () async => true,
        getServerUrl: () => 'https://example.supabase.co',
        clock: () => now,
      );

  http.Response Function(http.Request) ok(Map<String, Object?> body) =>
      (r) => http.Response(jsonEncode(body), 200,
          headers: {'content-type': 'application/json'}, request: r);

  setUp(() {
    now = DateTime.utc(2026, 1, 1);
    calls = 0;
  });

  test('false (production) is unsupported; true is verified', () async {
    reply = ok({'sync_seq': false, 'awaiting_fx_transactions': true});
    final s = svc();
    expect(await s.syncSeq(), ServerCapabilityState.unsupported);
    reply = ok({'sync_seq': true});
    now = now.add(const Duration(minutes: 16));
    expect(await s.syncSeq(), ServerCapabilityState.verified);
  });

  test('an answer is cached, then re-probed after the TTL (kill switch)',
      () async {
    reply = ok({'sync_seq': true});
    final s = svc();
    expect(await s.syncSeq(), ServerCapabilityState.verified);
    expect(await s.syncSeq(), ServerCapabilityState.verified);
    expect(calls, 1);
    reply = ok({'sync_seq': false}); // capability withdrawn
    now = now.add(ServerCapabilitiesService.syncSeqTtl +
        const Duration(seconds: 1));
    expect(await s.syncSeq(), ServerCapabilityState.unsupported);
    expect(calls, 2);
  });

  test('a server/network error is unknown, never "absent"', () async {
    reply = (r) => http.Response('boom', 503, request: r);
    expect(await svc().syncSeq(), ServerCapabilityState.unknown);
  });
}
