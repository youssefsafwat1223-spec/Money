import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/core/session/app_session.dart';
import '../../harness/egress_test_support.dart';
import 'package:money_companion/core/session/admission_authority.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'f2_fixture.dart';
import 'recording_secure_storage.dart';

String jwt(String uid, int expiry) {
  String part(Map<String, Object> value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${part({'alg': 'none'})}.${part({'sub': uid, 'exp': expiry})}.';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late F2Fixture f;
  setUp(() async => f = await F2Fixture.create());
  tearDown(() async => f.dispose());
  Future<SupabaseClient> expiredClient(
      {bool deny = false, bool fail = false}) async {
    var calls = 0;
    final client = SupabaseClient('http://127.0.0.1:55321', 'synthetic-anon',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
      calls++;
      if (calls > 1 && deny) return http.Response('{"msg":"denied"}', 403);
      if (calls > 1 && fail) throw StateError('synthetic transport failure');
      return http.Response(
          jsonEncode({
            'access_token': jwt(
                'uid-x',
                calls == 1
                    ? 1
                    : DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600),
            'token_type': 'bearer',
            'refresh_token': 'synthetic-refresh',
            'user': {'id': 'uid-x', 'email': 'uid-x@example.com'},
          }),
          200);
    }));
    await client.auth
        .signInWithPassword(email: 'uid-x@example.com', password: 'synthetic');
    return client;
  }

  for (final failure in ['denied', 'failed']) {
    test('expired session with $failure refresh attempts no admission effects',
        () async {
      await f.signIn('uid-x');
      final client = await expiredClient(
          deny: failure == 'denied', fail: failure == 'failed');
      final from = f.storage.attempts.length;
      final scopeFrom = f.scope.calls.length;
      final artifacts = await f.artifactsOf('uid-x');
      await expectLater(client.auth.refreshSession(), throwsA(anything));
      await f.session.revalidateSupabaseSessionOnResume(client);
      expect(f.session.status, isNot(SessionStatus.authenticated));
      expect(f.storage.attempts.skip(from), isEmpty);
      expect(f.scope.calls.skip(scopeFrom), isEmpty);
      expect(await f.artifactsOf('uid-x'), artifacts);
      await client.dispose();
    });
  }
  test('genuinely successful refresh restores admitted existing owner',
      () async {
    await f.signIn('uid-x');
    final client = await expiredClient();
    await f.session.revalidateSupabaseSessionOnResume(client);
    expect(f.session.status, SessionStatus.sessionExpired);
    await client.auth.refreshSession();
    expect(client.auth.currentSession!.isExpired, isFalse);
    await f.session.revalidateSupabaseSessionOnResume(client);
    expect(f.session.status, SessionStatus.authenticated);
    await client.dispose();
  });
  test(
      'expired session with no owner never attempts marker key registry or replica',
      () async {
    final client = await expiredClient();
    f.session.authMethod = 'google';
    final from = f.storage.attempts.length;
    await f.session.revalidateSupabaseSessionOnResume(client);
    expect(f.storage.attempts.skip(from), isEmpty);
    expect(f.scope.calls, isEmpty);
    expect(await f.artifactsOf('uid-x'), isEmpty);
    await client.dispose();
  });
  test('wrong UID maintenance authority cannot be rebound to live session',
      () async {
    await f.signIn('uid-x');
    final client = await f.clientFor('uid-x');
    final from = f.storage.attempts.length;
    final scopeFrom = f.scope.calls.length;
    await f.session.revalidateSupabaseSessionOnResume(client,
        authority: const AdmissionAuthority.forTest('other'));
    expect(f.storage.attempts.skip(from), isEmpty);
    expect(f.scope.calls.skip(scopeFrom), isEmpty);
  });
  test('session superseded during owner read cannot reopen or write', () async {
    await f.signIn('uid-x');
    final client = await f.clientFor('uid-x');
    final hold =
        f.storage.holdOnce((op, key) => op == 'read' && key == kMarkerKey);
    final from = f.storage.attempts.length;
    final scopeFrom = f.scope.calls.length;
    final pending = f.session.revalidateSupabaseSessionOnResume(client);
    await hold.reached.future;
    await client.auth.signOut(scope: SignOutScope.local);
    hold.release.complete();
    await pending;
    expect(f.storage.attempts.skip(from), isEmpty);
    expect(f.scope.calls.skip(scopeFrom), isEmpty);
  });
  test('expired pending owner conflict does not claim incoming owner',
      () async {
    await f.signIn('uid-y');
    final client = await expiredClient();
    final from = f.storage.attempts.length;
    await f.session.resolvePendingLocalDataOwnerConflict(client);
    await f.session.revalidateSupabaseSessionOnResume(client);
    expect(f.storage.attempts.skip(from), isEmpty);
    expect(await f.session.readLocalDataOwnerUid(), 'uid-y');
    expect(await f.artifactsOf('uid-x'), isEmpty);
    await client.dispose();
  });
  test('invalid explicit capability rejects before all admission effects',
      () async {
    final from = f.storage.attempts.length;
    await expectLater(
        f.session.setIdentity(
            method: 'google', userId: 'uid-x', sessionCurrent: () => false),
        throwsA(isA<StaleAdmissionException>()));
    expect(f.storage.attempts.skip(from), isEmpty);
    expect(f.scope.calls, isEmpty);
    expect(await f.artifactsOf('uid-x'), isEmpty);
  });
  test('explicit capability superseded during ownership read cannot create',
      () async {
    var valid = true;
    final hold =
        f.storage.holdOnce((op, key) => op == 'read' && key == kMarkerKey);
    final from = f.storage.attempts.length;
    final pending = f.session.setIdentity(
        method: 'google', userId: 'uid-x', sessionCurrent: () => valid);
    final rejected =
        expectLater(pending, throwsA(isA<StaleAdmissionException>()));
    await hold.reached.future;
    valid = false;
    hold.release.complete();
    await rejected;
    expect(f.storage.attempts.skip(from), isEmpty);
    expect(f.scope.calls, isEmpty);
    expect(await f.artifactsOf('uid-x'), isEmpty);
  });
  test('fresh explicit capability after removal admits once', () async {
    await f.signIn('uid-x');
    await f.session.removeDataFromDevice();
    final client = await f.clientFor('uid-x');
    final captured = client.auth.currentSession!;
    bool valid() =>
        !captured.isExpired &&
        client.auth.currentSession?.user.id == captured.user.id &&
        client.auth.currentSession?.accessToken == captured.accessToken;
    final scopeFrom = f.scope.calls.length;
    await f.session
        .setIdentity(method: 'google', userId: 'uid-x', sessionCurrent: valid);
    expect(
        f.scope.calls.skip(scopeFrom).where((call) => call == 'activate:uid-x'),
        hasLength(1));
    expect(await f.session.readLocalDataOwnerUid(), 'uid-x');
    expect(
        await f.artifactsOf('uid-x'), containsAll(['dir', 'key', 'registry']));
  });

  test(
      'expired replacement during held owner read prevents all admission effects',
      () async {
    await f.signIn('uid-x');
    var expiry = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
    final client = SupabaseClient('http://127.0.0.1:55321', 'synthetic-anon',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((_) async => http.Response(
            jsonEncode({
              'access_token': jwt('uid-x', expiry),
              'token_type': 'bearer',
              'user': {'id': 'uid-x'},
            }),
            200)));
    await client.auth
        .signInWithPassword(email: 'x@example.test', password: 'synthetic');
    final hold =
        f.storage.holdOnce((op, key) => op == 'read' && key == kMarkerKey);
    final from = f.storage.attempts.length;
    final scopeFrom = f.scope.calls.length;
    final pending = f.session.revalidateSupabaseSessionOnResume(client);
    await hold.reached.future;
    expiry = 1;
    await client.auth
        .signInWithPassword(email: 'x@example.test', password: 'synthetic');
    expect(client.auth.currentSession!.isExpired, isTrue);
    hold.release.complete();
    await pending;
    expect(f.storage.attempts.skip(from), isEmpty);
    expect(f.scope.calls.skip(scopeFrom), isEmpty);
    await client.dispose();
  });
  test('attempt during removal does not retire required revoke traffic', () async {
    final egress = TestEgress().install();
    await f.signIn('uid-x');
    f.scope.holdAfterDetach = Hold();
    final removal = f.session.removeDataFromDevice();
    await f.scope.holdAfterDetach!.reached.future;
    final epoch = egress.gate.epoch;
    f.session.beginAuthAttempt();
    expect(egress.gate.epoch, epoch);
    f.scope.holdAfterDetach!.release.complete();
    await removal;
  });

}
