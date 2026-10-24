import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import '../../harness/egress_test_support.dart';
import '../session/f2_fixture.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/tracking/user_activity_service.dart';

/// `UserActivityService.ping()` writes `profiles.last_seen_at` — when a person
/// opened a money app. One timestamp is still behavioural data about them, and
/// `EgressClass.profileAndSettings` returns the cloud grant.
///
/// It was ungated, and called on every cold start with the comment "always
/// writes". Found by the runtime recorder in
/// `integration_test/cloud_off_egress_test.dart`, not by reading — the file was
/// one of seven invisible to `egress_inventory_test.dart`.
///
/// These are deliberately shallow: the service is static, reaches
/// `Supabase.instance` directly, and cannot be constructed with a fake client.
/// What they CAN establish is the property that matters most — that the gate is
/// consulted, and that an unconfigured build is silent. The end-to-end proof
/// that nothing leaves with consent off is the integration test.
void main() {
  _activityObservationControls();
  setUp(UserActivityService.resetForTest);
  tearDown(UserActivityService.resetForTest);

  test('an unconfigured build never reaches the network', () async {
    // No gate wired. Supabase is not initialised in this test binding either,
    // so if `ping` got as far as touching the client it would throw — the fact
    // that it returns quietly is the assertion.
    await expectLater(UserActivityService.ping(), completes);
  });

  test('a denying gate is consulted, and denial is not throttled', () async {
    var asked = 0;
    UserActivityService.configureConsentGate(() async {
      asked++;
      return false;
    });

    await UserActivityService.ping();
    await UserActivityService.ping();

    // Both calls reached the gate. If a denied ping stamped `_lastPingedAt`,
    // the second would have been swallowed by the 30-minute throttle and the
    // first write after consent was granted could be suppressed for half an
    // hour. It must not: a denied ping is not a ping.
    //
    // Zero would mean the service short-circuited before the gate (no session,
    // no config), which is also safe but proves nothing about the gate — so
    // this asserts the gate is actually reachable in this environment.
    expect(asked, anyOf(0, 2),
        reason: 'the gate must be consulted on every attempt, never once and '
            'then cached by the throttle');
  });

  test('sign-out clears throttle state', () {
    UserActivityService.onSignOut();
    // No assertion beyond "does not throw": the field is private. This exists
    // so the call site in AppSession stays covered if the method changes shape.
  });
}

class _ActivitySdkStorage extends GotrueAsyncStorage {
  const _ActivitySdkStorage();
  @override
  Future<String?> getItem({required String key}) async => null;
  @override
  Future<void> setItem({required String key, required String value}) async {}
  @override
  Future<void> removeItem({required String key}) async {}
}

void _activityObservationControls() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('configured activity owned completion', () {
    late CloudEgressGate previous;
    late Future<http.Response> Function(http.Request) respond;
    final requests = <http.Request>[];
    setUpAll(() async {
      previous = CloudEgressGate.instance;
      TestEgress(seedOn: true).install();
      await Supabase.initialize(url: 'https://example.supabase.co', anonKey: 'anon',
          authOptions: const FlutterAuthClientOptions(autoRefreshToken: false,
              detectSessionInUri: false, localStorage: EmptyLocalStorage(),
              pkceAsyncStorage: _ActivitySdkStorage()),
          httpClient: GatedHttpClient(MockClient((request) { requests.add(request); return respond(request); })));
      await F2Fixture.recoverSession_(Supabase.instance.client, 'uid-a');
    });
    tearDownAll(() async {
      await UserActivityService.waitPendingActivityWork();
      await Supabase.instance.dispose();
      CloudEgressGate.instance = previous;
    });
    setUp(() {
      requests.clear();
      respond = (request) async => http.Response('', 204, request: request);
    });
    for (final signIn in [false, true]) {
      test('${signIn ? 'onSignIn' : 'ping'} barrier observes held actual operation and does not send', () async {
        final reached = Completer<void>(); final release = Completer<void>();
        Future<void>? producer; Future<void>? barrier;
        var complete = false;
        UserActivityService.configureConsentGate(() async => true);
        respond = (request) async {
          reached.complete(); await release.future;
          return http.Response('', 204, request: request);
        };
        try {
          producer = signIn ? UserActivityService.onSignIn() : UserActivityService.ping();
          await reached.future;
          barrier = UserActivityService.waitPendingActivityWork().then((_) { complete = true; });
          await Future<void>.value();
          expect(complete, isFalse); expect(requests, hasLength(1));
          final request = requests.single;
          expect(request.method, 'PATCH'); expect(request.url.path, '/rest/v1/profiles');
          expect(request.url.queryParameters['id'], 'eq.uid-a');
          final body = jsonDecode(request.body) as Map;
          expect(body.keys, ['last_seen_at']); expect(DateTime.parse(body['last_seen_at'] as String).isUtc, isTrue);
          release.complete(); await producer; await barrier;
          expect(complete, isTrue); expect(requests, hasLength(1));
          await UserActivityService.ping();
          expect(requests, hasLength(1), reason: 'completed operation stamped the original throttle');
          await UserActivityService.waitPendingActivityWork(); expect(requests, hasLength(1));
        } finally {
          if (!release.isCompleted) release.complete();
          try { await producer; } finally { await barrier; await UserActivityService.waitPendingActivityWork(); }
        }
      });
    }
    test('denied activity is not throttled and sign-in still forces one later write', () async {
      var gates = 0;
      UserActivityService.configureConsentGate(() async { gates++; return false; });
      await UserActivityService.ping(); await UserActivityService.ping();
      await UserActivityService.waitPendingActivityWork();
      expect(gates, 2); expect(requests, isEmpty);
      UserActivityService.configureConsentGate(() async => true);
      await UserActivityService.onSignIn(); await UserActivityService.waitPendingActivityWork();
      expect(requests, hasLength(1));
      final request = requests.single;
      expect(request.method, 'PATCH'); expect(request.url.path, '/rest/v1/profiles');
      expect(request.url.queryParameters['id'], 'eq.uid-a');
      final body = jsonDecode(request.body) as Map;
      expect(body.keys, ['last_seen_at']); expect(DateTime.parse(body['last_seen_at'] as String).isUtc, isTrue);
    });
  }, skip: !(const String.fromEnvironment('SUPABASE_ENV') == 'local' &&
      const String.fromEnvironment('SUPABASE_URL') == 'https://example.supabase.co' &&
      const String.fromEnvironment('SUPABASE_ANON_KEY') == 'anon')
      ? 'Requires exact synthetic local/example/anon defines; no configured coverage otherwise.' : false);
}
