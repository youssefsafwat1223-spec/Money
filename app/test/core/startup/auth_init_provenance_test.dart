// Stream-error injection uses the SDK's internal notifier; no production use.
// ignore_for_file: invalid_use_of_internal_member, invalid_use_of_protected_member

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/core/startup/bootstrap_runner.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// Astra R45 R11 + R12 — startup provenance through the REAL `Supabase.initialize`
// with synthetic persisted state, SharedPreferences mocked at the platform
// boundary and the transport behind the production gate (unresolved, so it denies
// everything) over a counting inner client.
//
//  R12: verified empty storage and a valid (even expired) session are benign;
//       unreadable, malformed, wrongly shaped or inconsistently loaded state is
//       UNKNOWN provenance and denies restoration; an unrelated stream error is
//       neutral; explicit signedOut / userDeleted are restrictive.
//  R11: the persisted session is found under the SDK's own key, the observation
//       is attached before the SDK can emit anything, and nothing escapes.

const _url = 'https://abcdefghij.supabase.co';
const _key = 'sb-abcdefghij-auth-token';

String _jwt(String uid, int exp) {
  String part(Map<String, Object> value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${part({'alg': 'none'})}.${part({'sub': uid, 'exp': exp})}.';
}

String _session({String uid = 'uid-prov', required int exp}) => jsonEncode({
      'access_token': _jwt(uid, exp),
      'token_type': 'bearer',
      'expires_in': 3600,
      'refresh_token': 'synthetic-refresh',
      'user': {
        'id': uid,
        'app_metadata': <String, Object>{},
        'user_metadata': <String, Object>{},
        'aud': 'authenticated',
        'created_at': '2024-01-01T00:00:00.000Z',
        'email': '$uid@example.com',
      },
    });

final _future = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 7200;

/// A store whose loads are scripted: `has[i]` / `raw[i]` answer the i-th call.
class _ScriptedStorage extends LocalStorage {
  _ScriptedStorage(
      {this.has = const [], this.raw = const [], this.throwRaw = false});
  final List<bool> has;
  final List<String?> raw;
  final bool throwRaw;
  int _h = 0;
  int _r = 0;
  @override
  Future<void> initialize() async {}
  @override
  Future<bool> hasAccessToken() async => has[(_h++).clamp(0, has.length - 1)];
  @override
  Future<String?> accessToken() async {
    if (throwRaw) throw StateError('storage unreadable');
    return raw[(_r++).clamp(0, raw.length - 1)];
  }

  @override
  Future<void> removePersistedSession() async {}
  @override
  Future<void> persistSession(String persistSessionString) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late int escaped; // requests that got past the production gate
  late AuthInitEventBuffer buffer;

  Future<void> initialize({
    Map<String, Object> prefs = const {},
    LocalStorage? inner,
    bool observing = true,
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    buffer = AuthInitEventBuffer();
    final counting = MockClient((request) async {
      escaped++;
      return http.Response('{}', 200);
    });
    await Supabase.initialize(
      url: _url,
      anonKey: 'synthetic-anon',
      httpClient: GatedHttpClient(counting),
      authOptions: FlutterAuthClientOptions(
        detectSessionInUri: false,
        localStorage: observing
            ? ObservingAuthLocalStorage(buffer, _url, inner: inner)
            : null,
      ),
    );
    // Let the SDK's unawaited `recoverSession()` and any gated refresh settle.
    await Future<void>.delayed(const Duration(milliseconds: 80));
  }

  setUp(() {
    escaped = 0;
    CloudEgressGate.instance = CloudEgressGate(); // unresolved: denies all
  });

  tearDown(() async {
    if (Supabase.instance.isInitialized) {
      await Supabase.instance.dispose();
    }
    await buffer.release();
  });

  group('R12 persisted-state provenance (real Supabase.initialize)', () {
    test('verified empty storage is benign', () async {
      await initialize();
      expect(buffer.provenanceIntact, isTrue);
      expect(Supabase.instance.client.auth.currentSession, isNull);
      expect(escaped, 0);
    });

    test('a valid unexpired persisted session is benign and found', () async {
      await initialize(prefs: {_key: _session(exp: _future)});
      expect(buffer.provenanceIntact, isTrue);
      expect(Supabase.instance.client.auth.currentSession?.user.id, 'uid-prov');
      expect(escaped, 0);
    });

    test('ordinary expiry with a RETRYABLE gated refresh failure is benign',
        () async {
      await initialize(prefs: {_key: _session(exp: 1)});
      expect(buffer.provenanceIntact, isTrue,
          reason: 'valid expired state; the denied refresh is not a loss');
      expect(buffer.sawRestrictiveLoss, isFalse);
      expect(Supabase.instance.client.auth.currentSession?.isExpired, isTrue);
      expect(escaped, 0, reason: 'the gate kept the refresh off the network');
    });

    test(
        'malformed persisted JSON is unknown provenance (a plain null '
        'initial session would otherwise look like absence)', () async {
      await initialize(prefs: {_key: '{this is not json'});
      expect(Supabase.instance.client.auth.currentSession, isNull,
          reason: 'the SDK itself degraded to a null initial session');
      expect(buffer.provenanceIntact, isFalse);
      expect(buffer.unknownProvenanceReason, 'malformed_session');
      expect(escaped, 0);
    });

    test('an invalid session shape is not a benign absence', () async {
      await initialize(prefs: {
        _key: jsonEncode(
            {'access_token': 'x', 'token_type': 'bearer', 'user': 'nope'})
      });
      expect(Supabase.instance.client.auth.currentSession, isNull);
      expect(buffer.provenanceIntact, isFalse);
      expect(buffer.unknownProvenanceReason, 'malformed_session');
    });

    test('a JSON value that is not an object is not a benign absence',
        () async {
      await initialize(prefs: {_key: '[1,2,3]'});
      expect(buffer.provenanceIntact, isFalse);
    });

    test('inconsistent storage: it says a session exists but loads none',
        () async {
      await initialize(inner: _ScriptedStorage(has: [true], raw: [null]));
      expect(buffer.provenanceIntact, isFalse);
      expect(buffer.unknownProvenanceReason, 'inconsistent_storage');
    });

    test('inconsistent storage: the two startup loads disagree', () async {
      final good = _session(exp: _future);
      await initialize(
          inner: _ScriptedStorage(has: [true, false], raw: [good, good]));
      expect(buffer.provenanceIntact, isFalse);
      expect(buffer.unknownProvenanceReason, 'inconsistent_storage');
      final other = _session(uid: 'uid-other', exp: _future);
      await Supabase.instance.dispose();
      await buffer.release();
      await initialize(
          inner: _ScriptedStorage(has: [true, true], raw: [good, other]));
      expect(buffer.provenanceIntact, isFalse);
    });

    test(
        'unreadable storage makes initialization fail and marks the '
        'provenance unknown', () async {
      SharedPreferences.setMockInitialValues({});
      buffer = AuthInitEventBuffer();
      await expectLater(
          Supabase.initialize(
            url: _url,
            anonKey: 'synthetic-anon',
            httpClient: GatedHttpClient(
                MockClient((_) async => http.Response('{}', 200))),
            authOptions: FlutterAuthClientOptions(
              detectSessionInUri: false,
              localStorage: ObservingAuthLocalStorage(buffer, _url,
                  inner: _ScriptedStorage(
                      has: [true], raw: [null], throwRaw: true)),
            ),
          ),
          throwsA(anything));
      expect(buffer.provenanceIntact, isFalse);
      expect(buffer.unknownProvenanceReason, 'storage_unreadable');
    });

    test(
        'an unrelated stream error is neutral: no classification by '
        'exception', () async {
      await initialize();
      final auth = Supabase.instance.client.auth;
      auth.notifyException(const AuthException('unrelated'));
      auth.notifyException(AuthRetryableFetchException(message: 'offline'));
      auth.notifyException(StateError('whatever'));
      await Future<void>.delayed(Duration.zero);
      expect(buffer.provenanceIntact, isTrue);
      expect(buffer.sawRestrictiveLoss, isFalse);
    });

    for (final event in [
      AuthChangeEvent.signedOut,
      AuthChangeEvent.userDeleted
    ]) {
      test('explicit $event is restrictive', () async {
        await initialize(prefs: {_key: _session(exp: _future)});
        Supabase.instance.client.auth.notifyAllSubscribers(event);
        await Future<void>.delayed(Duration.zero);
        expect(buffer.sawRestrictiveLoss, isTrue);
        expect(buffer.provenanceIntact, isFalse);
      });
    }
  });

  group('R11 SDK dependency contract', () {
    test(
        'the observing store uses the SDK default key: an existing persisted '
        'session is found by the SDK under it', () async {
      expect(ObservingAuthLocalStorage.sdkStorageKey(_url), _key);
      // The SDK's OWN default store (no custom store) finds the same key.
      await initialize(prefs: {_key: _session(exp: _future)}, observing: false);
      expect(Supabase.instance.client.auth.currentSession?.user.id, 'uid-prov',
          reason:
              'the SDK default key must equal ObservingAuthLocalStorage\'s');
    });

    test(
        'the observation is attached BEFORE the SDK emits anything: a '
        'signedOut raised during initialization is already seen when '
        'initialize returns', () async {
      // Valid JSON, Session.fromJson yields null -> the SDK signs out during its
      // own initialization and emits signedOut.
      SharedPreferences.setMockInitialValues({
        _key: jsonEncode({'foo': 'bar'})
      });
      buffer = AuthInitEventBuffer();
      await Supabase.initialize(
        url: _url,
        anonKey: 'synthetic-anon',
        httpClient:
            GatedHttpClient(MockClient((_) async => http.Response('{}', 200))),
        authOptions: FlutterAuthClientOptions(
          detectSessionInUri: false,
          localStorage: ObservingAuthLocalStorage(buffer, _url),
        ),
      );
      // No extra settle delay: only what `initialize` itself awaited.
      await Future<void>.delayed(Duration.zero);
      expect(buffer.sawRestrictiveLoss || buffer.unknownProvenance, isTrue);
      expect(buffer.provenanceIntact, isFalse);
    });

    test(
        'the persisted state is read twice at startup and both reads are '
        'observed (initialize + recoverSession)', () async {
      final storage = _CountingStorage(_session(exp: _future));
      await initialize(inner: storage);
      expect(storage.hasCalls, greaterThanOrEqualTo(2));
      expect(buffer.provenanceIntact, isTrue);
    });
  });
}

class _CountingStorage extends LocalStorage {
  _CountingStorage(this.raw);
  final String raw;
  int hasCalls = 0;
  @override
  Future<void> initialize() async {}
  @override
  Future<bool> hasAccessToken() async {
    hasCalls++;
    return true;
  }

  @override
  Future<String?> accessToken() async => raw;
  @override
  Future<void> removePersistedSession() async {}
  @override
  Future<void> persistSession(String persistSessionString) async {}
}
