import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'fake_account_scope.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';

  @override
  Future<String?> readStoredKey() async => 'test-key';
}

SupabaseClient _client() => SupabaseClient(
      'https://example.supabase.co',
      'public-anon-key',
      httpClient: MockClient((request) async => Response('{}', 200)),
    );

Future<void> _recoverSession(SupabaseClient client) async {
  String segment(Map<String, dynamic> json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  final header = segment({'alg': 'none', 'typ': 'JWT'});
  final payload = segment({
    'exp':
        DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/
            1000,
    'sub': 'uid-1',
  });
  await client.auth.recoverSession(jsonEncode({
    'access_token': '$header.$payload.',
    'token_type': 'bearer',
    'user': {'id': 'uid-1', 'email': 'user@example.com'},
  }));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late FakeAccountScope scope;

  Future<String> language() async => (await db
          .customSelect('SELECT language FROM user_settings LIMIT 1;')
          .getSingle())
      .read<String>('language');

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    AppSession.instance.configureCaptureOwnerClear(() async => true);
    await AppSession.instance.wipeAndReset();
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    await db.customStatement("UPDATE user_settings SET language = 'en';");
    scope = FakeAccountScope();
    AppSession.instance.configureAccountScope(scope);
  });

  tearDown(() async {
    AppSession.instance.configureCaptureOwnerClear(null);
    AppSession.instance.configureAccountScope(null);
    await AppSession.instance.wipeAndReset();
    await db.close();
  });

  test('server-driven signedOut expires session without wiping local data',
      () async {
    await AppSession.instance.completeOnboarding(
      method: 'google',
      email: 'user@example.com',
      userId: 'uid-1',
    );
    final client = _client();
    await _recoverSession(client);
    await AppSession.instance.bindSupabaseAuth(client);

    await client.auth.signOut();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(scope.calls.contains('lock'), isFalse,
        reason: 'a remote/session-expiry event is not an explicit request to '
            'destroy the local-first database');
    expect(AppSession.instance.status, SessionStatus.sessionExpired);
    expect(AppSession.instance.authMethod, 'google');
    expect(AppSession.instance.hasCompletedOnboarding, isTrue);
    expect(await language(), 'en', reason: 'the persisted row was wiped');
  });

  test('missing recovered session expires access without wiping local rows',
      () async {
    await AppSession.instance.completeOnboarding(
      method: 'google',
      email: 'user@example.com',
      userId: 'uid-1',
    );

    await AppSession.instance.revalidateSupabaseSessionOnResume(_client());

    expect(AppSession.instance.status, SessionStatus.sessionExpired);
    expect(scope.calls.contains('lock'), isFalse);
    expect(await language(), 'en', reason: 'session recovery wiped local data');
  });

  test('explicit user logout LOCKS the replica and never wipes it', () async {
    await AppSession.instance.completeOnboarding(
      method: 'google',
      email: 'user@example.com',
      userId: 'uid-1',
    );

    await AppSession.instance.signOut();

    expect(scope.calls.last, 'lock');
    expect(await language(), 'en',
        reason: 'explicit logout keeps the encrypted data (SYNC-Q2/Q8)');
    expect(AppSession.instance.status, SessionStatus.needsOnboarding);
  });
}
