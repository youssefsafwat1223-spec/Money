import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/core/auth/supabase_auth_service.dart' as app;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../harness/egress_test_support.dart';
import '../session/session_freshness_test.dart' show jwt;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final expired in [true, false]) {
    test(
        'OTP provider ${expired ? 'rejects expired' : 'binds fresh'} response capability',
        () async {
      TestEgress().install();
      var uid = 'uid-a';
      final client =
          SupabaseClient('https://example.supabase.co', 'synthetic-anon',
              authOptions: const AuthClientOptions(autoRefreshToken: false),
              httpClient: MockClient((_) async => http.Response(
                  jsonEncode({
                    'access_token': jwt(
                        uid,
                        expired
                            ? 1
                            : DateTime.now().millisecondsSinceEpoch ~/ 1000 +
                                3600),
                    'token_type': 'bearer',
                    'user': {'id': uid},
                  }),
                  200)));
      final service = app.SupabaseAuthService(client: client);
      if (expired) {
        await expectLater(
            service.verifyEmailCode(email: 'a@example.test', code: '123456'),
            throwsA(isA<app.AuthException>()));
      } else {
        final identity = (await service.verifyEmailCode(
            email: 'a@example.test', code: '123456'))!;
        expect(identity.isCurrent!(), isTrue);
        uid = 'uid-b';
        await client.auth
            .signInWithPassword(email: 'b@example.test', password: 'synthetic');
        expect(identity.isCurrent!(), isFalse);
      }
      await client.dispose();
    });
  }
}
