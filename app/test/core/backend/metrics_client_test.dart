import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';
import 'package:money_companion/core/backend/metrics_client.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// [currentUser] can be non-null from a locally-cached session even when the
/// underlying token is no longer valid server-side (a failed silent refresh
/// on cold start, exactly as observed live: `Invalid Refresh Token: Refresh
/// Token Not Found` immediately after `Supabase init completed`). Builds a
/// JWT with a future `exp` claim only — gotrue derives `Session.expiresAt`
/// purely from the local claim (no signature check), so `recoverSession`
/// accepts it and sets `currentUser` without any network call.
String _fakeNotYetExpiredAccessToken() {
  String segment(Map<String, dynamic> json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  final header = segment({'alg': 'none', 'typ': 'JWT'});
  final payload = segment({
    'exp':
        DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/
            1000,
    'sub': 'qa-user',
  });
  return '$header.$payload.';
}

void main() {
  test(
      'logEvent never throws when the metrics insert is rejected '
      '(stale-session RLS failure) — must not be able to block app bootstrap',
      () async {
    final http = MockClient((request) async {
      return Response(
        jsonEncode({
          'message':
              'new row violates row-level security policy for table "metrics"',
          'code': '42501',
          'details': 'Unauthorized',
        }),
        403,
        headers: const {'content-type': 'application/json'},
        request: request,
      );
    });
    final client = SupabaseClient(
      'https://example.supabase.co',
      'public-anon-key',
      httpClient: http,
    );
    await client.auth.recoverSession(jsonEncode({
      'access_token': _fakeNotYetExpiredAccessToken(),
      'token_type': 'bearer',
      'user': {'id': 'qa-user'},
    }));
    expect(client.auth.currentUser, isNotNull,
        reason: 'test setup must reproduce a non-null-but-invalid session');

    await expectLater(
      MetricsClient(client: client).logEvent('app_open'),
      completes,
    );
  });

  test('logEvent is a no-op with no signed-in user', () async {
    var called = false;
    final http = MockClient((request) async {
      called = true;
      return Response('{}', 200);
    });
    final client = SupabaseClient(
      'https://example.supabase.co',
      'public-anon-key',
      httpClient: http,
    );

    await MetricsClient(client: client).logEvent('app_open');

    expect(called, isFalse);
  });
}
