// ignore_for_file: unused_import, unused_element, unused_field, unused_element_parameter, unused_local_variable

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_local_notifications_platform_interface/flutter_local_notifications_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/core/privacy/consent_authority.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/core/session/capture_queue.dart';
import 'package:money_companion/core/session/local_read_authority.dart';
import 'package:money_companion/core/session/remove_data_flow.dart';
import 'package:money_companion/core/startup/bootstrap_runner.dart';
import 'package:money_companion/data/db/database_access_broker.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/data/db/replica_store.dart';
import 'package:money_companion/features/capture/services/capture_device_registration_service.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';
import 'package:path/path.dart' as p;
// ignore: depend_on_referenced_packages
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../session/f2_fixture.dart';
import '../session/recording_secure_storage.dart';

// Upgrade 52 -> 53 sign-in characterization (passes: the Dart-side upgrade state
// does NOT refuse the Apple id_token exchange; see the report for what remains).
// Upgrade 52 -> 53 sign-in repro. Based on the O-H2 harness: the REAL BootstrapRunner.run(): after removal-first handling and BEFORE
// ordinary replica recovery, adoption, retired purge and service init, an
// expired or absent SDK session with a valid grant restores the account's own
// replica read-only. Every effect is observed as an attempt.

class _SpyNotifications extends FlutterLocalNotificationsPlatform {
  static int initCalls = 0;
  @override
  Future<NotificationAppLaunchDetails?> getNotificationAppLaunchDetails() async {
    initCalls++;
    return null;
  }
}

class _Queue implements CaptureQueueBridge {
  int publishCalls = 0;
  int clearCalls = 0;
  CaptureRemovalBarrierRead barrier = const CaptureRemovalBarrierRead.absent();
  @override
  Future<CaptureRemovalBarrierRead> getCaptureRemovalBarrier() async => barrier;
  @override
  Future<void> beginCaptureRemoval(String uid) async {}
  @override
  Future<void> finishCaptureRemoval(String uid) async {
    barrier = const CaptureRemovalBarrierRead.absent();
  }

  @override
  Future<int> captureOwnerEpoch() async => 0;
  @override
  Future<bool> clearCaptureOwner({bool clearHint = false}) async {
    clearCalls++;
    return true;
  }
  @override
  Future<void> publishCaptureOwner({
    required String uid,
    required bool cloud,
    required bool ai,
    required int version,
    required int expectedEpoch,
    int? transitionGeneration,
  }) async {
    publishCalls++;
  }
}

class _CountingHttpOverrides extends HttpOverrides {
  static int created = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    created++;
    throw StateError('dart:io HttpClient created in a local-read test');
  }
}

String _jwt(String uid, int exp) {
  String part(Map<String, Object> value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${part({'alg': 'none'})}.${part({'sub': uid, 'exp': exp})}.';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const uid = 'uid-boot-a';
  late Directory support;
  late RecordingSecureStorage storage;
  late _Queue queue;
  final session = AppSession.instance;
  final runners = <BootstrapRunner>[];
  final clients = <SupabaseClient>[];
  Timer? frames;
  var httpRequests = 0;

  setUp(() async {
    support = Directory.systemTemp.createTempSync('bootstrap_lr_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => support.path,
    );
    storage = RecordingSecureStorage().install();
    FlutterLocalNotificationsPlatform.instance = _SpyNotifications();
    _SpyNotifications.initCalls = 0;
    queue = _Queue();
    session.debugResetAdmissionState();
    session.configureRemoveData(null);
    session.configureAccountScope(null);
    session.configureLocalRead(null);
    await session.wipeAndReset();
    final binding = TestWidgetsFlutterBinding.instance;
    frames = Timer.periodic(const Duration(milliseconds: 20), (_) {
      binding.scheduleFrame();
      binding.handleBeginFrame(Duration.zero);
      binding.handleDrawFrame();
    });
  });

  tearDown(() async {
    for (final r in [...runners]) {
      try {
        await r.accountScope.lock();
        r.accountScope.dispose();
      } catch (_) {}
    }
    for (final c in clients) {
      await c.dispose();
    }
    clients.clear();
    frames?.cancel();
    runners.clear();
    session.configureRemoveData(null);
    session.configureAccountScope(null);
    session.configureLocalRead(null);
    session.configureCaptureOwnerClear(null);
    support.deleteSync(recursive: true);
  });

  SupabaseClient absentClient() {
    final c = SupabaseClient('http://127.0.0.1:55321', 'synthetic-anon',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((_) async {
          httpRequests++;
          return http.Response('{}', 200);
        }));
    clients.add(c);
    return c;
  }

  Future<SupabaseClient> expiredClient() async {
    final c = SupabaseClient('http://127.0.0.1:55321', 'synthetic-anon',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          httpRequests++;
          return http.Response(
            jsonEncode({
              'access_token': _jwt(uid, 1),
              'token_type': 'bearer',
              'refresh_token': 'synthetic-refresh',
              'user': {'id': uid, 'email': '$uid@example.com'},
            }),
            200);
        }));
    await c.auth
        .signInWithPassword(email: '$uid@example.com', password: 'synthetic');
    clients.add(c);
    return c;
  }

  Future<BootstrapRunner> boot(SupabaseClient? client,
      {void Function(String)? events,
      Future<void> Function(SupabaseClient)? initialize}) async {
    final runner = BootstrapRunner(
        debugAuthClient: client,
        debugStorageEvent: events,
        debugAuthInitialize: initialize)
      ..captureQueue = queue;
    runners.add(runner);
    await runner.run();
    return runner;
  }

  /// A completed, receipted account with one known row, then a process that died
  /// while the replica was still `active` (nothing locked).
  Future<void> accountThenKill() async {
    final first = await boot(await F2Fixture.liveClient(uid));
    await session.completeOnboarding(
        method: 'google', email: '$uid@example.com', userId: uid);
    expect(first.accountScope.activeUid, uid);
    final now = DateTime.now().toUtc().toIso8601String();
    await first.accountScope.current!.database.customStatement(
        "INSERT INTO transactions(id, amount, amount_minor, currency, type, "
        "source, occurred_at, raw_message, parse_confidence, status, "
        "created_at, updated_at, raw_merchant, direction) VALUES "
        "('tx-1', 125.5, 12550, 'SAR', 'payment', 'manual', '$now', '', 1, "
        "'confirmed', '$now', '$now', 'Coffee Corner', 'debit');");
    final repo = DriftUserSettingsRepository(first.accountScope.current!.database);
    await repo.saveSettings((await repo.getSettings())
        .copyWith(cloudConsentState: ConsentState.accepted));
    await first.accountScope.detach();
    first.accountScope.dispose();
    runners.remove(first);
    session.debugResetAdmissionState();
    session.configureRemoveData(null);
    session.configureAccountScope(null);
  }


  // Build 52 never wrote any of these 53-only keys.
  void asBuild52Left() {
    storage.data.remove(SecureLocalReadStore.storageKey);
    storage.data.remove('qirsh.account_fence.v1');
    storage.data.remove(CloudEgressStore.kPendingSecureKey);
    storage.data.remove(RemoveDataFlow.barrierKey);
    storage.data.remove(RemoveDataFlow.revokedKey);
    // 52 left a durable ON record for the signed-in owner (cloud traffic flowed).
    final on = jsonEncode({
      'v': 1,
      'records': {
        uid: const CloudEgressRecord(
                state: EgressState.on,
                ownerUid: uid,
                transitionGeneration: 1,
                reservedVersion: 1)
            .toJson()
      }
    });
    storage.data[CloudEgressStore.kSecureKey] = on;
    File(p.join(support.path, CloudEgressStore.kFileName))
        .writeAsStringSync(on);
  }

  test('upgrade 52 -> 53: expired build-52 session, Apple id_token exchange '
      'reaches POST /auth/v1/token?grant_type=id_token', () async {
    const url = 'https://example.supabase.co';
    CloudEgressGate.instance = CloudEgressGate(supabaseUrl: () => url);
    await accountThenKill();
    asBuild52Left();

    final reached = <http.BaseRequest>[];
    final live = SupabaseClient(url, 'synthetic-anon',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: GatedHttpClient(MockClient((request) async {
          reached.add(request);
          return http.Response(
              jsonEncode({
                'access_token': _jwt(uid, 4102444800),
                'token_type': 'bearer',
                'expires_in': 3600,
                'expires_at': 4102444800,
                'refresh_token': 'r',
                'user': {
                  'id': uid,
                  'aud': 'authenticated',
                  'email': '$uid@example.com',
                  'created_at': '2026-01-01T00:00:00Z',
                  'app_metadata': <String, dynamic>{},
                  'user_metadata': <String, dynamic>{},
                },
              }),
              200,
              headers: {'content-type': 'application/json'});
        })));
    clients.add(live);

    final runner = await boot(await expiredClient());
    expect(runner.accountScope.current!.isLocalRead, isFalse);
    final gate = CloudEgressGate.instance;

    // The exact call SupabaseAuthService.signInWithApple makes after the sheet.
    Object? failure;
    try {
      await gate.runAccountControl(
          AccountControlOp.signIn,
          () => live.auth.signInWithIdToken(
              provider: OAuthProvider.apple,
              idToken: 'apple-id-token',
              nonce: 'raw-nonce'));
    } catch (e) {
      failure = e;
    }
    expect(failure, isNull, reason: 'sign-in must not be refused before network');
    expect(
        reached.where((r) =>
            r.method == 'POST' &&
            r.url.path == '/auth/v1/token' &&
            r.url.queryParameters['grant_type'] == 'id_token'),
        hasLength(1));
  });

  test('upgrade 52 -> 54: signed-out Dart with a surviving native active owner '
      'must still admit the Apple id_token exchange (no EgressDenied:frozen)',
      () async {
    const url = 'https://example.supabase.co';
    const channel = MethodChannel('money_companion/native_capture');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    NativeCaptureBridge.debugTreatHostAsNative = true;
    // Native still holds the build-52 active owner (Keychain), so the ownerless
    // query is `uncertain`; the owner's own record is a clean ON.
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getCloudEgressState') {
        final owner = (call.arguments as Map)['ownerUid'] as String;
        if (owner.isEmpty) return {'status': 'uncertain'};
        return {
          'status': 'record',
          'state': 'ON',
          'ownerUid': owner,
          'transitionGeneration': 1,
          'reservedVersion': 1,
        };
      }
      return null;
    });
    addTearDown(() {
      NativeCaptureBridge.debugTreatHostAsNative = false;
      ConsentAuthority.egressFrozen = false;
      messenger.setMockMethodCallHandler(channel, null);
    });
    ConsentAuthority.egressFrozen = false;
    CloudEgressGate.instance = CloudEgressGate(supabaseUrl: () => url);

    final reached = <http.BaseRequest>[];
    final live = SupabaseClient(url, 'synthetic-anon',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: GatedHttpClient(MockClient((request) async {
          reached.add(request);
          return http.Response(
              jsonEncode({
                'access_token': _jwt(uid, 4102444800),
                'token_type': 'bearer',
                'expires_in': 3600,
                'expires_at': 4102444800,
                'refresh_token': 'r',
                'user': {
                  'id': uid,
                  'aud': 'authenticated',
                  'email': '$uid@example.com',
                  'created_at': '2026-01-01T00:00:00Z',
                  'app_metadata': <String, dynamic>{},
                  'user_metadata': <String, dynamic>{},
                },
              }),
              200,
              headers: {'content-type': 'application/json'});
        })));
    clients.add(live);

    // Dart side: no owner marker, no session (what the upgraded device shows).
    await boot(absentClient());
    final gate = CloudEgressGate.instance;

    Object? failure;
    try {
      await gate.runAccountControl(
          AccountControlOp.signIn,
          () => live.auth.signInWithIdToken(
              provider: OAuthProvider.apple,
              idToken: 'apple-id-token',
              nonce: 'raw-nonce'));
    } catch (e) {
      failure = e;
    }
    expect(failure, isNull,
        reason: 'sign-in must not be refused before network: $failure');
    expect(
        reached.where((r) =>
            r.method == 'POST' &&
            r.url.path == '/auth/v1/token' &&
            r.url.queryParameters['grant_type'] == 'id_token'),
        hasLength(1));
    // Privacy: ordinary egress stays denied while the state is uncertain.
    await expectLater(
        live.rest.from('transactions').select(),
        throwsA(isA<EgressDeniedException>()));
    expect(reached.where((r) => r.url.path.startsWith('/rest/')), isEmpty);

    // Signing in names the owner: the per-owner reconciliation then judges the
    // real uid's clean ON record and lifts the freeze (nothing before it did).
    expect(ConsentAuthority.egressFrozen, isTrue);
    final db = runners.last.accountScope.current!.database;
    final repo = DriftUserSettingsRepository(db);
    await repo.saveSettings((await repo.getSettings())
        .copyWith(cloudConsentState: ConsentState.accepted));
    await CaptureDeviceRegistrationService(
      settingsRepository: repo,
      gate: gate,
      readReplicaOwnerUid: () async => uid,
      readSession: () => null,
    ).resolvePendingDisable();
    expect(ConsentAuthority.egressFrozen, isFalse);
  });

  test('upgrade 52 -> 53 over the REAL Supabase.initialize wiring: the Apple '
      'id_token exchange reaches the network', () async {
    const url = 'https://abcdefghij.supabase.co';
    SharedPreferences.setMockInitialValues({});
    CloudEgressGate.instance = CloudEgressGate(supabaseUrl: () => url);
    await accountThenKill();
    asBuild52Left();
    final reached = <http.BaseRequest>[];
    final expired = jsonEncode({
      'access_token': _jwt(uid, 1),
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
    final runner = BootstrapRunner(
        debugSdk: BootstrapSdkTestConfig(
          url: url,
          innerStorage: _Store(expired),
          innerHttp: MockClient((request) async {
            reached.add(request);
            final exp = DateTime.now()
                    .add(const Duration(hours: 1))
                    .millisecondsSinceEpoch ~/
                1000;
            return http.Response(
                jsonEncode({
                  'access_token': _jwt(uid, exp),
                  'token_type': 'bearer',
                  'expires_in': 3600,
                  'expires_at': exp,
                  'refresh_token': 'r',
                  'user': {
                    'id': uid,
                    'aud': 'authenticated',
                    'email': '$uid@example.com',
                    'created_at': '2026-01-01T00:00:00Z',
                    'app_metadata': <String, dynamic>{},
                    'user_metadata': <String, dynamic>{},
                  },
                }),
                200,
                headers: {'content-type': 'application/json'});
          }),
        ))
      ..captureQueue = queue;
    runners.add(runner);
    await runner.run();
    final gate = CloudEgressGate.instance;
    Object? failure;
    try {
      await gate.runAccountControl(
          AccountControlOp.signIn,
          () => Supabase.instance.client.auth.signInWithIdToken(
              provider: OAuthProvider.apple,
              idToken: 'apple-id-token',
              nonce: 'raw-nonce'));
    } catch (e) {
      failure = e;
    }
    expect(failure, isNull);
    expect(reached.where((r) => r.url.queryParameters['grant_type'] == 'id_token'),
        hasLength(1));
    await Supabase.instance.dispose();
    CloudEgressGate.instance = CloudEgressGate();
  });
}

class _Store extends LocalStorage {
  _Store(this.session);
  final String session;
  @override
  Future<void> initialize() async {}
  @override
  Future<bool> hasAccessToken() async => true;
  @override
  Future<String?> accessToken() async => session;
  @override
  Future<void> removePersistedSession() async {}
  @override
  Future<void> persistSession(String persistSessionString) async {}
}
