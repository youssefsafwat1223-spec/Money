import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/core/privacy/consent_authority.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../harness/egress_test_support.dart';

/// Astra H2.1 / H2.6-B: the operation-scoped OFF allowlist, driven through the
/// REAL supabase / gotrue / postgrest clients (pinned versions) and a spy inner
/// client, so the endpoints asserted here are the ones the packages emit.
const _url = 'https://example.supabase.co';

class _MemStorage extends GotrueAsyncStorage {
  final _m = <String, String>{};
  @override
  Future<String?> getItem({required String key}) async => _m[key];
  @override
  Future<void> removeItem({required String key}) async => _m.remove(key);
  @override
  Future<void> setItem({required String key, required String value}) async =>
      _m[key] = value;
}

String _jwt(int exp) {
  String b(Object o) =>
      base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return '${b({'alg': 'HS256'})}.${b({'sub': 'uid-a', 'exp': exp})}.sig';
}

Map<String, dynamic> _sessionJson({required bool expired}) {
  final exp = DateTime.now()
          .add(Duration(hours: expired ? -2 : 1))
          .millisecondsSinceEpoch ~/
      1000;
  return {
    'access_token': _jwt(exp),
    'token_type': 'bearer',
    'expires_in': 3600,
    'expires_at': exp,
    'refresh_token': 'refresh',
    'user': {
      'id': 'uid-a',
      'aud': 'authenticated',
      'created_at': '2026-01-01T00:00:00Z',
      'app_metadata': <String, dynamic>{},
      'user_metadata': <String, dynamic>{},
      'email': 'a@b.c',
    },
  };
}

class _Spy {
  final seen = <http.BaseRequest>[];
  bool follow = true;
  late final http.Client client = MockClient.streaming((req, body) async {
    seen.add(req);
    follow = req.followRedirects;
    final path = req.url.path;
    Object json = <String, dynamic>{};
    if (path == '/auth/v1/token' || path == '/auth/v1/verify') {
      json = _sessionJson(expired: false);
    } else if (path.startsWith('/rest/v1/rpc/')) {
      json = '2026-02-01T00:00:00Z';
    } else if (path.startsWith('/rest/v1/')) {
      json = <Object>[];
    }
    return http.StreamedResponse(
        Stream.value(utf8.encode(jsonEncode(json))), 200,
        headers: const {'content-type': 'application/json'}, request: req);
  });
  List<String> get calls => [
        for (final r in seen)
          '${r.method} ${r.url.path}${r.url.query.isEmpty ? '' : '?${r.url.query}'}'
      ];
}

void main() {
  late TestEgress egress; // OFF: no record at all
  late _Spy spy;
  late SupabaseClient client;

  SupabaseClient build() => SupabaseClient(_url, 'anon',
      httpClient: GatedHttpClient(spy.client),
      authOptions: AuthClientOptions(
          autoRefreshToken: false, pkceAsyncStorage: _MemStorage()));

  void setUpGate(
      {Duration ttl = kAccountControlTtl, Duration Function()? mono}) {
    egress = TestEgress(accountControlTtl: ttl, monotonic: mono).install();
    spy = _Spy();
    client = build();
  }

  setUp(() => setUpGate());

  Future<Object?> expectDenied(Future<Object?> Function() f) async {
    try {
      await f();
    } catch (e) {
      return e;
    }
    return null;
  }

  group('allowed inside their own op, nothing else', () {
    test('signIn: Google/Apple id_token, email otp and verify', () async {
      await gateRun(
          AccountControlOp.signIn,
          () => client.auth
              .signInWithIdToken(provider: OAuthProvider.google, idToken: 'x'));
      await gateRun(AccountControlOp.signIn,
          () => client.auth.signInWithOtp(email: 'a@b.c'));
      await gateRun(
          AccountControlOp.signIn,
          () => client.auth
              .verifyOTP(email: 'a@b.c', token: '123456', type: OtpType.email));
      expect(spy.calls, [
        'POST /auth/v1/token?grant_type=id_token',
        'POST /auth/v1/otp',
        'POST /auth/v1/verify',
      ]);
    });

    test('reauthenticate has the same allowlist as signIn', () async {
      await gateRun(
          AccountControlOp.reauthenticate,
          () => client.auth.signInWithIdToken(
              provider: OAuthProvider.apple, idToken: 'x', nonce: 'n'));
      expect(spy.calls, ['POST /auth/v1/token?grant_type=id_token']);
    });

    test('deleteAccount: the RPC, and the refresh an expired token needs',
        () async {
      await client.auth
          .setInitialSession(jsonEncode(_sessionJson(expired: true)));
      final r = await gateRun(AccountControlOp.deleteAccount,
          () => client.rpc('request_account_deletion'));
      expect(r, '2026-02-01T00:00:00Z');
      expect(spy.calls, [
        'POST /auth/v1/token?grant_type=refresh_token',
        'POST /rest/v1/rpc/request_account_deletion',
      ]);
    });

    test('cancelDelete: the RPC, and the refresh an expired token needs',
        () async {
      await client.auth
          .setInitialSession(jsonEncode(_sessionJson(expired: true)));
      await gateRun(AccountControlOp.cancelDelete,
          () => client.rpc('cancel_account_deletion'));
      expect(spy.calls, [
        'POST /auth/v1/token?grant_type=refresh_token',
        'POST /rest/v1/rpc/cancel_account_deletion',
      ]);
    });

    test('no grant, no OFF traffic: the same calls are denied unwrapped',
        () async {
      expect(
          await expectDenied(() => client.auth
              .signInWithIdToken(provider: OAuthProvider.google, idToken: 'x')),
          isNotNull);
      expect(await expectDenied(() => client.rpc('cancel_account_deletion')),
          isNotNull);
      expect(spy.seen, isEmpty);
    });
  });

  group('everything else is denied during an allowance', () {
    const ops = AccountControlOp.values;
    for (final op in ops) {
      test(
          '$op: PostgREST, other RPC, functions, storage, /user, refresh '
          '(unless delete/cancel) never reach the inner client', () async {
        await client.auth
            .setInitialSession(jsonEncode(_sessionJson(expired: false)));
        final attempts = <Future<Object?> Function()>[
          () => client.from('profiles').select(),
          () => client.rpc('get_referral_summary'),
          () => client.rpc('record_metric', params: {'p_metric_key': 'k'}),
          () => client.functions.invoke('catalog-versions'),
          () => client.storage.from('b').list(),
          () => client.auth.getUser(),
          () => client.auth.signOut(),
          if (op == AccountControlOp.signIn) () => client.auth.refreshSession(),
        ];
        await gateRun(op, () async {
          for (final a in attempts) {
            expect(await expectDenied(a), isNotNull);
          }
        });
        expect(spy.seen, isEmpty,
            reason: 'zero requests reached the inner client');
      });
    }

    test('a delete grant does not authorize the cancel RPC and vice versa',
        () async {
      await client.auth
          .setInitialSession(jsonEncode(_sessionJson(expired: false)));
      await gateRun(AccountControlOp.deleteAccount, () async {
        expect(await expectDenied(() => client.rpc('cancel_account_deletion')),
            isNotNull);
      });
      await gateRun(AccountControlOp.cancelDelete, () async {
        expect(await expectDenied(() => client.rpc('request_account_deletion')),
            isNotNull);
      });
      expect(spy.seen, isEmpty);
    });

    test('another host / scheme / user-info is denied', () async {
      await gateRun(AccountControlOp.signIn, () async {
        for (final u in [
          'https://evil.example.com/auth/v1/otp',
          'http://example.supabase.co/auth/v1/otp',
          'https://u@example.supabase.co/auth/v1/otp',
          'https://example.supabase.co/auth/v1/otp?redirect_to=x',
        ]) {
          expect(
              await expectDenied(() => egress.gate
                  .admit(request: AdmissionRequest('POST', Uri.parse(u)))),
              isA<EgressDeniedException>(),
              reason: u);
        }
        expect(
            await expectDenied(() => egress.gate.admit(
                request:
                    AdmissionRequest('GET', Uri.parse('$_url/auth/v1/otp')))),
            isA<EgressDeniedException>());
      });
    });
  });

  group('the allowance disappears', () {
    Future<String?> admitIn(Zone z) => z.run(() async {
          try {
            final t = await egress.gate.admit(
                request:
                    AdmissionRequest('POST', Uri.parse('$_url/auth/v1/otp')));
            egress.gate.release(t);
            return null;
          } on EgressDeniedException catch (e) {
            return e.reason;
          }
        });

    test('on success: a zone timer / retry that fires afterwards is denied',
        () async {
      final late = Completer<String?>();
      await gateRun(AccountControlOp.signIn, () async {
        // Active now:
        expect(await admitIn(Zone.current), isNull);
        Timer(const Duration(milliseconds: 60), () async {
          late.complete(await admitIn(Zone.current));
        });
      });
      expect(await late.future, 'grant_inactive');
    });

    test('on failure', () async {
      late Zone z;
      await expectLater(
          gateRun(AccountControlOp.signIn, () async {
            z = Zone.current;
            throw StateError('boom');
          }),
          throwsStateError);
      expect(await admitIn(z), 'grant_inactive');
    });

    test(
        'on timeout (monotonic TTL): body cancelled, grant ended, in-flight '
        'request aborted', () async {
      setUpGate(ttl: const Duration(milliseconds: 80));
      late Zone z;
      await expectLater(
          gateRun(AccountControlOp.signIn, () async {
            z = Zone.current;
            await Completer<void>().future; // never completes
          }),
          throwsA(isA<TimeoutException>()));
      expect(await admitIn(z), 'grant_inactive');
    });

    test('expiry is measured on the injected monotonic clock', () async {
      var now = Duration.zero;
      setUpGate(mono: () => now);
      await gateRun(AccountControlOp.signIn, () async {
        expect(await admitIn(Zone.current), isNull);
        now += kAccountControlTtl; // exactly the TTL: expired
        expect(await admitIn(Zone.current), 'grant_inactive');
      });
    });

    test('an unrelated concurrent call never inherits the grant', () async {
      final started = Completer<void>();
      final release = Completer<void>();
      final op = gateRun(AccountControlOp.signIn, () async {
        started.complete();
        await release.future;
      });
      await started.future;
      expect(
          await expectDenied(() => egress.gate.admit(
              request:
                  AdmissionRequest('POST', Uri.parse('$_url/auth/v1/otp')))),
          isA<EgressDeniedException>());
      release.complete();
      await op;
    });
  });

  group('no widening, no redirects', () {
    test('the store, the record and consent are untouched by every op',
        () async {
      final before = (egress.secure.value, egress.file.value);
      for (final op in AccountControlOp.values) {
        await client.auth
            .setInitialSession(jsonEncode(_sessionJson(expired: true)));
        await gateRun(op, () async {
          if (op == AccountControlOp.deleteAccount) {
            await client.rpc('request_account_deletion');
          } else if (op == AccountControlOp.cancelDelete) {
            await client.rpc('cancel_account_deletion');
          } else {
            await client.auth.signInWithOtp(email: 'a@b.c');
          }
        });
      }
      expect((egress.secure.value, egress.file.value), before);
      expect(egress.secure.writes + egress.file.writes, 0);
      expect(await egress.gate.permits(), isFalse, reason: 'Cloud stays OFF');
      expect(egress.gate.permitNotifier.value, isFalse);
      expect(egress.gate.permitsNetworkSync, isFalse);
      expect((await egress.gate.view()).record, isNull);
      expect(ConsentAuthority.egressFrozen, isFalse);
    });

    test(
        'a granted request is sent with followRedirects=false; ordinary '
        'traffic is untouched', () async {
      await gateRun(AccountControlOp.signIn,
          () => client.auth.signInWithOtp(email: 'a@b.c'));
      expect(spy.follow, isFalse);
      await egress.gate.enable(owner: 'uid-a', reservedVersion: 1);
      await client.from('profiles').select();
      expect(spy.follow, isTrue);
    });

    test('a 3xx answer is returned as-is (never followed to another host)',
        () async {
      final inner = MockClient.streaming((req, _) async {
        spy.seen.add(req);
        return http.StreamedResponse(const Stream.empty(), 302,
            headers: const {'location': 'https://evil.example.com/'},
            request: req,
            isRedirect: true);
      });
      final c = SupabaseClient(_url, 'anon',
          httpClient: GatedHttpClient(inner),
          authOptions: AuthClientOptions(
              autoRefreshToken: false, pkceAsyncStorage: _MemStorage()));
      await expectLater(
          gateRun(AccountControlOp.signIn,
              () => c.auth.signInWithOtp(email: 'a@b.c')),
          throwsA(isA<AuthException>()));
      expect(spy.seen.length, 1);
      expect(spy.seen.single.followRedirects, isFalse);
    });
  });

  group('state still wins over a grant', () {
    test('unresolved, frozen and DISABLING deny a grant; uncertain too',
        () async {
      Future<String?> reason() => gateRun(AccountControlOp.signIn, () async {
            try {
              final t = await egress.gate.admit(
                  request:
                      AdmissionRequest('POST', Uri.parse('$_url/auth/v1/otp')));
              egress.gate.release(t);
              return null;
            } on EgressDeniedException catch (e) {
              return e.reason;
            }
          });
      expect(await reason(), isNull, reason: 'OFF/unset + grant = allowed');

      final unresolved = TestEgress(resolved: false).install();
      expect(
          await unresolved.gate.runAccountControl(AccountControlOp.signIn,
              () async {
            try {
              await unresolved.gate.admit(
                  request:
                      AdmissionRequest('POST', Uri.parse('$_url/auth/v1/otp')));
              return null;
            } on EgressDeniedException catch (e) {
              return e.reason;
            }
          }),
          'unresolved');

      egress = TestEgress().install();
      ConsentAuthority.egressFrozen = true;
      expect(await reason(), 'frozen');
      ConsentAuthority.egressFrozen = false;
      await egress.gate.beginDisabling(owner: 'uid-a', reservedVersion: 2);
      expect(await reason(), 'disabling');
      egress = TestEgress().install();
      egress.file.value = '{broken';
      expect(await reason(), 'state_uncertain');
    });
  });

  group('sign-out while OFF is local and sends nothing', () {
    test(
        'the session is cleared, the persisted-session event fires, the '
        'inner client is never reached', () async {
      await client.auth
          .setInitialSession(jsonEncode(_sessionJson(expired: false)));
      final events = <AuthChangeEvent>[];
      final sub =
          client.auth.onAuthStateChange.listen((d) => events.add(d.event));
      Object? thrown;
      try {
        await client.auth.signOut();
      } catch (e) {
        thrown = e; // the denied server logout; callers already swallow it
      }
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(client.auth.currentSession, isNull);
      expect(client.auth.currentUser, isNull);
      expect(events, contains(AuthChangeEvent.signedOut));
      expect(thrown, isA<AuthRetryableFetchException>());
      expect(spy.seen, isEmpty);
    });
  });

  group('url_launcher', () {
    test(
        'denied unless permitted; an allowlisted host inside an active grant '
        'is the only exception', () async {
      final web = Uri.parse('https://example.com/privacy');
      final own = Uri.parse('$_url/anything');
      expect(await egress.gate.mayLaunchExternal(web), isFalse);
      expect(await egress.gate.mayLaunchExternal(own), isFalse);
      await gateRun(AccountControlOp.signIn, () async {
        expect(await egress.gate.mayLaunchExternal(web), isFalse);
        expect(await egress.gate.mayLaunchExternal(own), isTrue);
      });
      expect(await egress.gate.mayLaunchExternal(own), isFalse);
      await egress.gate.enable(owner: 'uid-a', reservedVersion: 1);
      expect(await egress.gate.mayLaunchExternal(web), isTrue);
    });
  });
}

Future<T> gateRun<T>(AccountControlOp op, Future<T> Function() body) =>
    CloudEgressGate.instance.runAccountControl(op, body);
