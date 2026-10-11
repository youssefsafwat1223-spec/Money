import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'session_freshness_test.dart' show jwt;
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'f2_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('held onboarding completion cannot publish after authentication loss',
      () async {
    final f = await F2Fixture.create();
    try {
      await f.session.setIdentity(method: 'google', userId: 'uid-x');
      final hold = f.storage
          .holdOnce((op, key) => op == 'write' && key == 'onboarding_done');
      final finish = f.session.finishOnboarding();
      await hold.reached.future;
      f.session.markSessionInvalid();
      final from = f.storage.attempts.length;
      hold.release.complete();
      await finish;
      expect(f.session.status, SessionStatus.sessionExpired);
      expect(f.storage.attempts.skip(from), isEmpty);
    } finally {
      await f.dispose();
    }
  });
  for (final scenario in [
    'expired before finish',
    'expired during finish',
    'valid refresh during finish'
  ]) {
    test('onboarding $scenario respects live session without new admission',
        () async {
      final f = await F2Fixture.create();
      var expiry = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
      final client = SupabaseClient('http://127.0.0.1:55321', 'synthetic-anon',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
          httpClient: MockClient((_) async => http.Response(
              jsonEncode({
                'access_token': jwt('uid-x', expiry),
                'token_type': 'bearer',
                'refresh_token': 'synthetic-refresh',
                'user': {'id': 'uid-x'},
              }),
              200)));
      try {
        await client.auth
            .signInWithPassword(email: 'x@example.test', password: 'synthetic');
        await f.session.setIdentity(method: 'google', userId: 'uid-x');
        final from = f.storage.attempts.length;
        if (scenario == 'expired before finish') {
          expiry = 1;
          await client.auth.signInWithPassword(
              email: 'x@example.test', password: 'synthetic');
          await f.session.finishOnboarding(client: client);
          expect(f.storage.attempts.skip(from), isEmpty);
        } else {
          final hold = f.storage
              .holdOnce((op, key) => op == 'write' && key == 'onboarding_done');
          final finish = f.session.finishOnboarding(client: client);
          await hold.reached.future;
          expiry = scenario == 'expired during finish' ? 1 : expiry + 3600;
          await client.auth.refreshSession();
          final invalidFrom = f.storage.attempts.length;
          hold.release.complete();
          await finish;
          if (scenario == 'expired during finish') {
            expect(f.storage.attempts.skip(invalidFrom), isEmpty);
          }
        }
        expect(
            f.session.status,
            scenario == 'valid refresh during finish'
                ? SessionStatus.authenticated
                : isNot(SessionStatus.authenticated));
      } finally {
        await client.dispose();
        await f.dispose();
      }
    });
  }
}
