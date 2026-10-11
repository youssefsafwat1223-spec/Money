import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:money_companion/core/session/app_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('expired current session cannot promote existing owner to authenticated',
      () async {
    FlutterSecureStorage.setMockInitialValues({});
    final session = AppSession.instance;
    session.configureCaptureOwnerClear(() async => true);
    await session.completeOnboarding(
        method: 'google', userId: 'existing-owner');
    String segment(Map<String, Object> value) =>
        base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
    final token = '${segment({'alg': 'none'})}.${segment({
          'sub': 'existing-owner',
          'exp': 1
        })}.';
    final client = SupabaseClient('http://127.0.0.1:55321', 'synthetic-anon',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((_) async => http.Response(
            jsonEncode({
              'access_token': token,
              'token_type': 'bearer',
              'user': {'id': 'existing-owner'},
            }),
            200)));
    await client.auth
        .signInWithPassword(email: 'a@example.test', password: 'synthetic');
    expect(client.auth.currentSession!.isExpired, isTrue);
    session.markSessionInvalid();
    expect(session.status, SessionStatus.sessionExpired);
    await session.bindSupabaseAuth(client);
    // Security regression: expired authentication cannot publish a live scope.
    expect(session.status, isNot(SessionStatus.authenticated));
    await client.dispose();
  });
}
