import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/core/session/account_scope.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../harness/egress_test_support.dart';
import 'f2_fixture.dart';
import 'session_freshness_test.dart' show jwt;

void main() => refreshEpochCase('signout');

void refreshEpochCase(String lifecycle,
    {bool failure = false, bool refreshDuringProvider = false}) {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'real gated late ${failure ? 'failed' : 'successful'} refresh after $lifecycle${refreshDuringProvider ? ' while provider pending' : ''} cannot restore old authority',
      () async {
    final egress = TestEgress(seedOn: true).install();
    final f = await F2Fixture.create(initialize: (db, uid) async {
      // The production capture_registration bootstrap step advances this
      // epoch each time the new account scope is initialized.
      egress.gate.advanceEpoch();
      return const AccountScopeInit();
    });
    final reached = Completer<void>();
    final release = Completer<void>();
    var uid = 'uid-a';
    final client = SupabaseClient(
        'https://example.supabase.co', 'synthetic-anon',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: GatedHttpClient(MockClient((request) async {
      final responseUid = uid;
      final responseExpiry = DateTime.now().millisecondsSinceEpoch ~/ 1000 +
          (request.url.queryParameters['grant_type'] == 'refresh_token'
              ? 1800
              : 3600);
      if (request.url.queryParameters['grant_type'] == 'refresh_token') {
        reached.complete();
        await release.future;
        if (failure) {
          return http.Response('{"msg":"synthetic invalid refresh"}', 400);
        }
      }
      return http.Response(
          jsonEncode({
            'access_token': jwt(responseUid, responseExpiry),
            'token_type': 'bearer',
            'refresh_token': 'synthetic-refresh',
            'user': {'id': responseUid},
          }),
          200);
    })));
    try {
      await client.auth
          .signInWithPassword(email: 'a@example.test', password: 'synthetic');
      await f.signIn('uid-a');
      await f.session.bindSupabaseAuth(client);
      final providerAttempt =
          refreshDuringProvider ? f.session.beginAuthAttempt() : null;
      final refresh = client.auth.refreshSession();
      final rejected = expectLater(refresh, throwsA(anything));
      await reached.future;
      if (lifecycle == 'new login' ||
          lifecycle == 'same UID reauthentication') {
        final attempt = providerAttempt ?? f.session.beginAuthAttempt();
        uid = lifecycle == 'new login' ? 'uid-b' : 'uid-a';
        await client.auth
            .signInWithPassword(email: 'b@example.test', password: 'synthetic');
        final captured = client.auth.currentSession!;
        await f.session.setIdentity(
            method: 'google',
            userId: uid,
            attempt: attempt,
            sessionCurrent: () =>
                !captured.isExpired &&
                client.auth.currentSession?.accessToken ==
                    captured.accessToken);
      } else if (lifecycle == 'removal') {
        await f.session.removeDataFromDevice();
        egress.gate.advanceEpoch(); // production signout callback
      } else {
        await f.session.signOut();
        egress.gate.advanceEpoch(); // production signout callback
      }
      final currentToken = client.auth.currentSession?.accessToken;
      final from = f.storage.attempts.length;
      final scopeFrom = f.scope.calls.length;
      release.complete();
      await rejected;
      await Future<void>.delayed(Duration.zero);
      await f.session.drainAdmissions();
      expect(f.storage.attempts.skip(from), isEmpty);
      expect(f.scope.calls.skip(scopeFrom), isEmpty);
      if (lifecycle == 'new login' ||
          lifecycle == 'same UID reauthentication') {
        expect(client.auth.currentSession?.user.id, uid);
        expect(client.auth.currentSession?.accessToken, currentToken);
        expect(await f.session.readLocalDataOwnerUid(), uid);
      } else {
        expect(f.session.status, isNot(SessionStatus.authenticated));
      }
    } finally {
      await client.dispose();
      await f.dispose();
    }
  });
}
