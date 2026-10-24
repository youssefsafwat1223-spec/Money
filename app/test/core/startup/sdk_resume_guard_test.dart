// The lifecycle events are delivered through the binding's protected entrance.
// ignore_for_file: invalid_use_of_protected_member

import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/core/startup/bootstrap_runner.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// Astra R45 R15 — the REAL pinned SDK: `Supabase.initialize` installs its
// lifecycle observer, and a resume calls `startAutoRefresh()` (one immediate
// refresh tick plus a periodic ticker) whatever Cloud says. With an expired
// persisted session that tick WOULD refresh. Through the production transport
// (the gate is unresolved/denying) and the production resume guard: zero
// requests escape, nothing is persisted, and no periodic ticker outlives the
// resume. A control without the guard proves the ticker measurement is real.

const _url = 'https://abcdefghij.supabase.co';
const _key = 'sb-abcdefghij-auth-token';

String _jwt(String uid, int exp) {
  String part(Map<String, Object> value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${part({'alg': 'none'})}.${part({'sub': uid, 'exp': exp})}.';
}

final _expiredSession = jsonEncode({
  'access_token': _jwt('uid-resume', 1),
  'token_type': 'bearer',
  'expires_in': 3600,
  'refresh_token': 'synthetic-refresh',
  'user': {
    'id': 'uid-resume',
    'app_metadata': <String, Object>{},
    'user_metadata': <String, Object>{},
    'aud': 'authenticated',
    'created_at': '2024-01-01T00:00:00.000Z',
    'email': 'uid-resume@example.com',
  },
});

class _TrackedTimer implements Timer {
  _TrackedTimer(this._inner, this.period, this._live);
  final Timer _inner;
  final Duration period;
  final Set<_TrackedTimer> _live;
  @override
  void cancel() {
    _live.remove(this);
    _inner.cancel();
  }

  @override
  bool get isActive => _inner.isActive;
  @override
  int get tick => _inner.tick;
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  late int escaped;
  late Set<_TrackedTimer> periodic;

  ZoneSpecification trackPeriodicTimers() => ZoneSpecification(
        createPeriodicTimer: (self, parent, zone, period, callback) {
          final inner = parent.createPeriodicTimer(zone, period, callback);
          final tracked = _TrackedTimer(inner, period, periodic);
          periodic.add(tracked);
          return tracked;
        },
      );

  setUp(() {
    escaped = 0;
    periodic = {};
    CloudEgressGate.instance = CloudEgressGate(); // unresolved: denies all
    SharedPreferences.setMockInitialValues({_key: _expiredSession});
  });

  tearDown(() async {
    if (Supabase.instance.isInitialized) await Supabase.instance.dispose();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  Future<void> cycle({required bool withGuard}) async {
    await runZoned(() async {
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
          localStorage: ObservingAuthLocalStorage(AuthInitEventBuffer(), _url),
        ),
      );
      final auth = Supabase.instance.client.auth;
      auth.stopAutoRefresh(); // exactly what bootstrap does right after init
      final guard = AutoRefreshResumeGuard();
      if (withGuard) guard.attach();
      addTearDown(() {
        if (withGuard) guard.detach();
      });
      await Future<void>.delayed(const Duration(milliseconds: 60));
      periodic.clear(); // only the resume's timers matter below
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }, zoneSpecification: trackPeriodicTimers());
  }

  test(
      'with the production resume guard: zero escaping refresh requests, '
      'nothing persisted, and no refresh ticker survives the resume', () async {
    await cycle(withGuard: true);
    expect(escaped, 0, reason: 'the gated transport denied the resume tick');
    expect(periodic.where((t) => t.isActive), isEmpty,
        reason: 'the guard stopped the periodic refresh ticker');
    final prefs = await SharedPreferences.getInstance();
    final stored = jsonDecode(prefs.getString(_key)!) as Map<String, dynamic>;
    final original = jsonDecode(_expiredSession) as Map<String, dynamic>;
    // The SDK re-serialises the SAME session on its own initial event; what must
    // never appear is a refreshed one.
    expect(stored['access_token'], original['access_token']);
    expect(stored['refresh_token'], original['refresh_token']);
  });

  test(
      'control: without the guard the SDK leaves its ticker running (the '
      'measurement is real); the transport still lets nothing out', () async {
    await cycle(withGuard: false);
    expect(periodic.where((t) => t.isActive), isNotEmpty,
        reason: 'the SDK itself restarts auto-refresh on resume');
    expect(escaped, 0, reason: 'the gate, not the timer, keeps it off the net');
    Supabase.instance.client.auth.stopAutoRefresh();
  });
}
