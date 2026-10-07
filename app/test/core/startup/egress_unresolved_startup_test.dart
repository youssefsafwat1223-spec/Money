import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/core/backend/metrics_client.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/features/referrals/services/referral_service.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../harness/egress_test_support.dart';

/// Astra H2.3 / H2.6-C: a fresh or upgraded install whose durable egress record
/// is missing, corrupt or unreadable. The bootstrap-equivalent sequence (an
/// UNRESOLVED gate, the REAL `Supabase.initialize` with the gated transport,
/// session restore of an EXPIRED token, then catalog / metric / referral /
/// onboarding triggers) must put ZERO requests on the inner client. The count is
/// taken on the inner client, not on the denials.
const _url = 'https://example.supabase.co';

String _jwt(int exp) {
  String b(Object o) =>
      base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return '${b({'alg': 'HS256'})}.${b({'sub': 'uid-a', 'exp': exp})}.sig';
}

String _expiredSession({bool expired = true}) {
  final exp = DateTime.now()
          .add(Duration(hours: expired ? -2 : 1))
          .millisecondsSinceEpoch ~/
      1000;
  return jsonEncode({
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
    },
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Real Supabase.initialize + retry timers.
  const slow = Timeout(Duration(seconds: 90));

  late List<http.BaseRequest> reached;

  // Each test's spy records into ITS OWN list: gotrue's refresh-retry loops of a
  // finished test may still run, and must never leak into the next test's count.
  http.Client spy() {
    final mine = reached;
    return MockClient.streaming((req, body) async {
      mine.add(req);
      final path = req.url.path;
      Object json = <String, dynamic>{};
      if (path == '/auth/v1/token') {
        final exp = DateTime.now()
                .add(const Duration(hours: 1))
                .millisecondsSinceEpoch ~/
            1000;
        json = jsonDecode(_expiredSession()) as Map<String, dynamic>
          ..['access_token'] = _jwt(exp)
          ..['expires_at'] = exp;
      } else if (path.startsWith('/rest/v1/rpc/')) {
        json = <String, dynamic>{};
      }
      return http.StreamedResponse(
          Stream.value(utf8.encode(jsonEncode(json))), 200,
          headers: const {'content-type': 'application/json'}, request: req);
    });
  }

  setUp(() async {
    reached = [];
    SharedPreferences.setMockInitialValues(
        {'sb-example-auth-token': _expiredSession()});
    final msg =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    msg.setMockMethodCallHandler(
        const MethodChannel('com.llfbandit.app_links/messages'),
        (c) async => null);
  });

  tearDown(() async {
    if (Supabase.instance.isInitialized) await Supabase.instance.dispose();
  });

  Future<void> triggers() async {
    final client = Supabase.instance.client;
    // The session is made valid first so these calls do not sit in gotrue's
    // 30 s refresh-retry loop; they are stopped by the gate, nothing else.
    await client.auth.setInitialSession(_expiredSession(expired: false));
    // catalog / flags, metric, referral, onboarding mark, rest.
    await client.functions
        .invoke('catalog-versions')
        .catchError((_) => FunctionResponse(status: 0));
    await MetricsClient().logEvent('app_open');
    await SupabaseReferralService().getSummary().catchError((_) => null);
    await client.rpc('mark_onboarding_completed').catchError((_) => null);
    await client
        .from('profiles')
        .select()
        .catchError((_) => <Map<String, dynamic>>[]);
  }

  Future<void> boot(TestEgress egress) async {
    egress.install();
    await Supabase.initialize(
        url: _url, anonKey: 'anon', httpClient: GatedHttpClient(spy()));
    // The restored (expired) session is there, so the metric trigger gets past
    // its own "signed in" check and is stopped only by the gate.
    expect(Supabase.instance.client.auth.currentUser, isNotNull);
    // gotrue's own refresh-retry timers get time to fire.
    await Future<void>.delayed(const Duration(milliseconds: 700));
  }

  final scenarios = <String, void Function(TestEgress)>{
    'missing record (fresh install / upgrade)': (_) {},
    'corrupt record': (e) => e.file.value = '{not json',
    'unreadable record': (e) => e.secure.failReads = true,
  };

  scenarios.forEach((name, arrange) {
    test(
        '$name: Supabase.initialize + expired-session restore + every trigger '
        'put ZERO requests on the inner client, before AND after resolution',
        timeout: slow, () async {
      final egress = TestEgress(resolved: false);
      arrange(egress);
      await boot(egress);
      expect(reached, isEmpty, reason: 'init + restore, unresolved');
      await triggers();
      expect(reached, isEmpty, reason: 'triggers, unresolved');

      egress.gate.markResolved(); // bootstrap finished the reconciliation
      await egress.gate.refresh();
      expect(await egress.gate.permits(), isFalse);
      await triggers();
      expect(reached, isEmpty,
          reason:
              'still nothing once resolved: absent/corrupt/unreadable != ON');
    });
  });

  test(
      'positive control: an ON record, unresolved => nothing; resolved => the '
      'spy DOES see traffic (so the zeros above are meaningful)', () async {
    final egress = TestEgress(resolved: false, seedOn: true);
    await boot(egress);
    expect(reached, isEmpty);
    egress.gate.markResolved();
    await Supabase.instance.client.rpc('mark_onboarding_completed');
    expect(reached.where((r) => r.url.path.contains('mark_onboarding')),
        isNotEmpty);
  });

  test(
      'the persisted expired session survives the unresolved start (no local '
      'sign-out), so an ON user is still signed in once resolved', () async {
    final egress = TestEgress(resolved: false);
    await boot(egress);
    expect(Supabase.instance.client.auth.currentSession, isNotNull);
  });
}
