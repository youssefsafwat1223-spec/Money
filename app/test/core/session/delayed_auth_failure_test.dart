import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/domain/errors/repo_exceptions.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'f2_fixture.dart';
import 'session_freshness_test.dart' show jwt;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final successor in ['same user admission', 'different user', 'refresh']) {
    test('delayed auth callback cannot revoke $successor', () async {
      final f = await F2Fixture.create();
      final client = await f.clientFor('uid-a');
      try {
        await f.signIn('uid-a');
        final failure = f.session.captureAuthRequiredFailure(client);
        if (successor == 'refresh') {
          await client.auth.recoverSession(jsonEncode({
            'access_token': jwt('uid-a',
                DateTime.now().millisecondsSinceEpoch ~/ 1000 + 7200),
            'token_type': 'bearer',
            'refresh_token': 'synthetic-refresh',
            'user': {'id': 'uid-a'},
          }));
        } else {
          final uid = successor == 'different user' ? 'uid-b' : 'uid-a';
          await f.signIn(uid);
          await f.recoverSession(client, uid);
        }
        final before = Map<String, String>.of(f.storage.data);
        final scope = f.host.current;
        await failure();
        expect(f.session.status, SessionStatus.authenticated);
        expect(f.storage.data, before);
        expect(f.host.current, same(scope));
        expect(client.auth.currentSession!.isExpired, isFalse);
      } finally {
        await client.dispose();
        await f.dispose();
      }
    });
  }
  test('current server auth rejection invalidates even a fresh SDK session', () async {
    final f = await F2Fixture.create();
    final client = await f.clientFor('uid-a');
    try {
      await f.signIn('uid-a');
      final failure = f.session.captureAuthRequiredFailure(client);
      final mapped = mapSupabaseError(
          const AuthException('synthetic rejection', statusCode: '401'));
      expect(mapped, isA<AuthRepoException>());
      if (mapped is AuthRepoException) await failure();
      expect(client.auth.currentSession!.isExpired, isFalse);
      expect(f.session.status, SessionStatus.sessionExpired);
      expect(f.session.hasCompletedOnboarding, isTrue);
      expect(await f.keyPresent('uid-a'), isTrue);
    } finally {
      await client.dispose();
      await f.dispose();
    }
  });
  test('retryable SDK transport and consent denial are not auth loss', () async {
    final f = await F2Fixture.create();
    final client = await f.clientFor('uid-a');
    try {
      await f.signIn('uid-a');
      final failure = f.session.captureAuthRequiredFailure(client);
      for (final error in [
        AuthRetryableFetchException(statusCode: '503'),
        EgressDeniedException('stale'),
        EgressDeniedException('consent'),
      ]) {
        final mapped = mapSupabaseError(error);
        expect(mapped, isNot(isA<AuthRepoException>()));
        if (mapped is AuthRepoException) await failure();
      }
      expect(f.session.status, SessionStatus.authenticated);
    } finally {
      await client.dispose();
      await f.dispose();
    }
  });
}
