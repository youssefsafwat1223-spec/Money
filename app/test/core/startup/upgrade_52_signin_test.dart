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
import 'package:money_companion/core/session/consent_capability.dart';
import 'package:money_companion/core/session/local_read_authority.dart';
import 'package:money_companion/core/session/remove_data_flow.dart';
import 'package:money_companion/core/startup/bootstrap_runner.dart';
import 'package:money_companion/data/db/database_access_broker.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/data/db/replica_store.dart';
import 'package:money_companion/features/capture/services/capture_device_registration_service.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';
import 'package:money_companion/features/onboarding/auth_screen.dart'
    show signInFailureCode;
import 'package:path/path.dart' as p;
// ignore: depend_on_referenced_packages
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../harness/native_enable_sim.dart';
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
  Future<NotificationAppLaunchDetails?>
      getNotificationAppLaunchDetails() async {
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
    final repo =
        DriftUserSettingsRepository(first.accountScope.current!.database);
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

  /// A NEW process over the durable fixtures: a fresh gate (the latch starts
  /// false), no freeze carried over. Durable stores are left untouched.
  CloudEgressGate freshProcess(String url) {
    ConsentAuthority.egressFrozen = false;
    ConsentAuthority.egressFreezeTag = '';
    final gate = CloudEgressGate(supabaseUrl: () => url);
    CloudEgressGate.instance = gate;
    expect(gate.isResolved, isFalse);
    return gate;
  }

  test(
      'upgrade 52 -> 53: expired build-52 session, Apple id_token exchange '
      'reaches POST /auth/v1/token?grant_type=id_token', () async {
    const url = 'https://example.supabase.co';
    CloudEgressGate.instance = CloudEgressGate(supabaseUrl: () => url);
    await accountThenKill();
    asBuild52Left();
    freshProcess(url);

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
    expect(failure, isNull,
        reason: 'sign-in must not be refused before network');
    expect(
        reached.where((r) =>
            r.method == 'POST' &&
            r.url.path == '/auth/v1/token' &&
            r.url.queryParameters['grant_type'] == 'id_token'),
        hasLength(1));
  });

  test(
      'upgrade 52 -> 54: signed-out Dart with a surviving native active owner '
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
    await expectLater(live.rest.from('transactions').select(),
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

  test(
      'upgrade 52 -> 53 over the REAL Supabase.initialize wiring: the Apple '
      'id_token exchange reaches the network', () async {
    const url = 'https://abcdefghij.supabase.co';
    SharedPreferences.setMockInitialValues({});
    CloudEgressGate.instance = CloudEgressGate(supabaseUrl: () => url);
    await accountThenKill();
    asBuild52Left();
    freshProcess(url);
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
    expect(
        reached.where((r) => r.url.queryParameters['grant_type'] == 'id_token'),
        hasLength(1));
    await Supabase.instance.dispose();
    CloudEgressGate.instance = CloudEgressGate();
  });
  // 55 device evidence: marker == uid (a surviving owner) while the build-52
  // access token is expired, and native cannot vouch for the NAMED owner. The
  // launch reconcile freezes (reconcile_uncertain), which stops the token
  // refresh, so the app is signed out with the owner marker still set.
  for (final retainedValidSession in [false, true]) {
    for (final nat in ['uncertain', 'null', 'throw', 'ownerless']) {
      test(
          'upgrade 52 -> 55: marker=uid, native=$nat, valid SDK=$retainedValidSession: '
          'launch freezes, sign-in still admitted, ordinary egress denied',
          () async {
        const url = 'https://abcdefghij.supabase.co';
        const channel = MethodChannel('money_companion/native_capture');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        var nativeClean = false;
        NativeCaptureBridge.debugTreatHostAsNative = true;
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method != 'getCloudEgressState') return null;
          final owner = (call.arguments as Map)['ownerUid'] as String;
          if (nativeClean && owner.isNotEmpty) {
            return {
              'status': 'record',
              'state': 'ON',
              'ownerUid': owner,
              'transitionGeneration': 1,
              'reservedVersion': 1,
            };
          }
          if (owner.isEmpty) return {'status': 'uncertain'};
          if (nat == 'uncertain') {
            return {'status': 'uncertain', 'reason': 'epoch_missing'};
          }
          if (nat == 'null') return null;
          if (nat == 'throw') throw PlatformException(code: 'x');
          return {'status': 'ownerless', 'ownerEpoch': 1, 'ownerGeneration': 1};
        });
        addTearDown(() {
          NativeCaptureBridge.debugTreatHostAsNative = false;
          ConsentAuthority.egressFrozen = false;
          ConsentAuthority.egressFreezeTag = '';
          messenger.setMockMethodCallHandler(channel, null);
        });
        ConsentAuthority.egressFrozen = false;
        SharedPreferences.setMockInitialValues({});
        CloudEgressGate.instance = CloudEgressGate(supabaseUrl: () => url);
        await accountThenKill();
        asBuild52Left();
        freshProcess(url);
        expect(storage.data['local_data_owner_uid'], uid);
        final reached = <http.BaseRequest>[];
        String session(int exp) => jsonEncode({
              'access_token': _jwt(uid, exp),
              'token_type': 'bearer',
              'expires_in': 3600,
              'expires_at': exp,
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
          innerStorage: _Store(session(retainedValidSession
              ? DateTime.now()
                      .add(const Duration(hours: 1))
                      .millisecondsSinceEpoch ~/
                  1000
              : 1)),
          innerHttp: MockClient((request) async {
            reached.add(request);
            return http.Response(
                session(DateTime.now()
                        .add(const Duration(hours: 1))
                        .millisecondsSinceEpoch ~/
                    1000),
                200,
                headers: {'content-type': 'application/json'});
          }),
        ))
          ..captureQueue = queue;
        runners.add(runner);
        await runner.run();
        final sdk = Supabase.instance;
        addTearDown(() => sdk.dispose());
        final auth = sdk.client.auth;
        final gate = CloudEgressGate.instance;
        if (retainedValidSession) {
          // Model the real launch-invalid origin while the SDK retains its token.
          // This revokes committed application authority without deleting identity.
          AppSession.instance.markSessionInvalid();
          expect(AppSession.instance.captureConsentCapability(), isNull);
          expect(auth.currentSession?.isExpired, isFalse);
        }

        // The chain: frozen at launch, no refresh, expired session = signed out.
        expect(ConsentAuthority.egressFrozen, isTrue);
        expect(
            ConsentAuthority.egressFreezeTag,
            'reconcile_uncertain:native:${{
              'uncertain': 'epoch_missing',
              'null': 'unknown',
              'throw': 'unknown',
              'ownerless': 'unknown',
            }[nat]}');
        expect(reached, isEmpty, reason: 'token refresh was blocked');
        expect(auth.currentSession?.isExpired, !retainedValidSession);
        expect(storage.data['local_data_owner_uid'], uid);
        expect(await gate.permits(), isFalse);

        // Interactive Apple sign-in must be admitted (it was EgressDenied:frozen).
        Object? failure;
        try {
          await gate.runAccountControl(
              AccountControlOp.signIn,
              () => auth.signInWithIdToken(
                  provider: OAuthProvider.apple,
                  idToken: 'apple-id-token',
                  nonce: 'raw-nonce'));
        } catch (e) {
          failure = e;
        }
        expect(failure, isNull, reason: 'sign-in refused: $failure');
        expect(
            reached.where((r) =>
                r.url.path == '/auth/v1/token' &&
                r.url.queryParameters['grant_type'] == 'id_token'),
            hasLength(1));
        // Privacy: ordinary egress stays denied while frozen, and the diagnostic
        // names the site.
        expect(ConsentAuthority.egressFrozen, isTrue);
        await expectLater(
            Supabase.instance.client.rest.from('transactions').select(),
            throwsA(isA<EgressDeniedException>()));
        expect(reached.where((r) => r.url.path.startsWith('/rest/')), isEmpty);
        expect(signInFailureCode(EgressDeniedException('frozen')),
            'EgressDenied:frozen/${ConsentAuthority.egressFreezeTag}');

        // SDK exchange alone is not committed application admission. While the
        // native evidence still blocks admission, explicit recovery stays usable.
        if (AppSession.instance.captureConsentCapability() == null) {
          await gate.runAccountControl(
              AccountControlOp.signIn,
              () => auth.signInWithIdToken(
                  provider: OAuthProvider.apple,
                  idToken: 'apple-id-token',
                  nonce: 'raw-nonce'));
          expect(ConsentAuthority.egressFrozen, isTrue);
          await expectLater(
              Supabase.instance.client.rest.from('transactions').select(),
              throwsA(isA<EgressDeniedException>()));
        } else {
          await expectLater(
              gate.runAccountControl(
                  AccountControlOp.signIn,
                  () => auth.signInWithIdToken(
                      provider: OAuthProvider.apple,
                      idToken: 'apple-id-token',
                      nonce: 'raw-nonce')),
              throwsA(predicate((e) => '$e'.contains('egress_denied:frozen'))));
        }

        // Once native can vouch for the owner, the per-owner reconcile lifts it.
        nativeClean = true;
        final db = runner.accountScope.current!.database;
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
        CloudEgressGate.instance = CloudEgressGate();
      });
    }
  }

  test(
      'upgrade 52 -> 56: native active owner is this uid but its generation '
      'counter disagrees (Keychain outlived a reinstall): the launch reconcile '
      're-claims the same owner and lifts the freeze', () async {
    const url = 'https://abcdefghij.supabase.co';
    const channel = MethodChannel('money_companion/native_capture');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var repaired = 0;
    NativeCaptureBridge.debugTreatHostAsNative = true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'repairActiveOwnerGeneration') {
        repaired++;
        return {'uid': uid, 'uidHash': 'h', 'generation': 9};
      }
      if (call.method != 'getCloudEgressState') return null;
      final owner = (call.arguments as Map)['ownerUid'] as String;
      if (owner.isEmpty) return {'status': 'uncertain'};
      if (repaired == 0) {
        return {'status': 'uncertain', 'reason': 'owner_generation_mismatch'};
      }
      return {
        'status': 'record',
        'state': 'ON',
        'ownerUid': owner,
        'transitionGeneration': 1,
        'reservedVersion': 1,
      };
    });
    addTearDown(() {
      NativeCaptureBridge.debugTreatHostAsNative = false;
      ConsentAuthority.egressFrozen = false;
      ConsentAuthority.egressFreezeTag = '';
      messenger.setMockMethodCallHandler(channel, null);
    });
    ConsentAuthority.egressFrozen = false;
    SharedPreferences.setMockInitialValues({});
    CloudEgressGate.instance = CloudEgressGate(supabaseUrl: () => url);
    await accountThenKill();
    asBuild52Left();
    freshProcess(url);
    repaired = 0; // the fixture boot above is another process
    final reached = <http.BaseRequest>[];
    String session(int exp) => jsonEncode({
          'access_token': _jwt(uid, exp),
          'token_type': 'bearer',
          'expires_in': 3600,
          'expires_at': exp,
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
      innerStorage: _Store(session(1)),
      innerHttp: MockClient((request) async {
        reached.add(request);
        return http.Response(
            session(DateTime.now()
                    .add(const Duration(hours: 1))
                    .millisecondsSinceEpoch ~/
                1000),
            200,
            headers: {'content-type': 'application/json'});
      }),
    ))
      ..captureQueue = queue;
    runners.add(runner);
    await runner.run();
    expect(repaired, 1);
    expect(ConsentAuthority.egressFrozen, isFalse,
        reason: 'tag: ${ConsentAuthority.egressFreezeTag}');
    expect(storage.data['local_data_owner_uid'], uid);
    await Supabase.instance.dispose();
    CloudEgressGate.instance = CloudEgressGate();
  });

  // Build 57 device evidence: `EgressDenied:unresolved` at sign-in. Marker=uid,
  // durable ON, expired SDK session, native generation counter disagrees. Every
  // case boots a NEW process (fresh gate, latch false) over the durable state.
  group('upgrade 56 -> 58: the startup latch always resolves', () {
    const url = 'https://abcdefghij.supabase.co';
    const channel = MethodChannel('money_companion/native_capture');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var repairs = 0;
    var mismatch = true;
    Completer<void>? holdNext; // the next owner-named native read waits on it
    Completer<void>? held; // the read that is waiting
    Completer<void>? heldReached;
    Completer<void>? repairGate; // a repair waits on it after committing
    Completer<void>? repairReached;
    var repairResult = true;
    late List<http.BaseRequest> reached;

    String sessionJson(int exp) => jsonEncode({
          'access_token': _jwt(uid, exp),
          'token_type': 'bearer',
          'expires_in': 3600,
          'expires_at': exp,
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

    setUp(() {
      repairs = 0;
      mismatch = true;
      holdNext = held = heldReached = repairGate = repairReached = null;
      repairResult = true;
      reached = [];
      NativeCaptureBridge.debugTreatHostAsNative = true;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'repairActiveOwnerGeneration') {
          repairs++;
          if (repairResult) mismatch = false; // committed natively
          repairReached?.complete();
          await repairGate?.future;
          if (!repairResult) return null;
          return {'uid': uid, 'uidHash': 'h', 'generation': 9};
        }
        if (call.method != 'getCloudEgressState') return null;
        final owner = (call.arguments as Map)['ownerUid'] as String;
        if (owner.isEmpty) return {'status': 'uncertain'};
        final hold = holdNext;
        if (hold != null) {
          holdNext = null;
          held = hold;
          heldReached?.complete();
          await hold.future;
        }
        if (mismatch) {
          return {'status': 'uncertain', 'reason': 'owner_generation_mismatch'};
        }
        return {
          'status': 'record',
          'state': 'ON',
          'ownerUid': owner,
          'transitionGeneration': 1,
          'reservedVersion': 1,
        };
      });
    });
    tearDown(() async {
      NativeCaptureBridge.debugTreatHostAsNative = false;
      ConsentAuthority.egressFrozen = false;
      ConsentAuthority.egressFreezeTag = '';
      messenger.setMockMethodCallHandler(channel, null);
      await Supabase.instance.dispose();
      CloudEgressGate.instance = CloudEgressGate();
    });

    BootstrapRunner newRunner() {
      final r = BootstrapRunner(
          debugSdk: BootstrapSdkTestConfig(
        url: url,
        innerStorage: _Store(sessionJson(1)),
        innerHttp: MockClient((request) async {
          reached.add(request);
          return http.Response(
              sessionJson(DateTime.now()
                      .add(const Duration(hours: 1))
                      .millisecondsSinceEpoch ~/
                  1000),
              200,
              headers: {'content-type': 'application/json'});
        }),
      ))
        ..captureQueue = queue;
      runners.add(r);
      return r;
    }

    /// The durable state build 56 left behind (optionally with its local-read
    /// grant), then a brand-new process: fresh gate, fresh native counters.
    Future<CloudEgressGate> prepare({bool keepGrant = false}) async {
      SharedPreferences.setMockInitialValues({});
      CloudEgressGate.instance = CloudEgressGate(supabaseUrl: () => url);
      await accountThenKill();
      final grant = storage.data[SecureLocalReadStore.storageKey];
      asBuild52Left();
      if (keepGrant) {
        expect(grant, isNotNull, reason: 'the fixture must leave a grant');
        storage.data[SecureLocalReadStore.storageKey] = grant!;
      }
      repairs = 0;
      mismatch = true;
      // The consent capability's identity evidence is the bound SDK client.
      session.configureConsentSdkClient(() {
        try {
          return Supabase.instance.client;
        } catch (_) {
          return null; // no SDK bound yet (the fixture process)
        }
      });
      return freshProcess(url);
    }

    Future<Object?> appleSignIn(CloudEgressGate gate) async {
      try {
        await gate.runAccountControl(
            AccountControlOp.signIn,
            () => Supabase.instance.client.auth.signInWithIdToken(
                provider: OAuthProvider.apple,
                idToken: 'apple-id-token',
                nonce: 'raw-nonce'));
        return null;
      } catch (e) {
        return e;
      }
    }

    /// The real SDK session loss. The session and the `signedOut` event happen
    /// first; the server logout call is itself (correctly) denied while the
    /// latch is unresolved, which is ignored here.
    Future<void> loseSession() => Supabase.instance.client.auth
        .signOut(scope: SignOutScope.local)
        .then<void>((_) {}, onError: (Object _) {});

    /// The app's real sign-in completion (auth_screen `_signIn`): the attempt is
    /// captured BEFORE the provider exchange, then `setIdentity` publishes the
    /// signed-in scope (its `initialize` is the production `_initializeAccount`).
    Future<void> productionAppleSignIn(CloudEgressGate gate) async {
      final client = Supabase.instance.client;
      final attempt = session.beginAuthAttempt();
      await gate.runAccountControl(
          AccountControlOp.signIn,
          () => client.auth.signInWithIdToken(
              provider: OAuthProvider.apple,
              idToken: 'apple-id-token',
              nonce: 'raw-nonce'));
      await session.setIdentity(
        method: 'apple',
        email: '$uid@example.com',
        userId: uid,
        attempt: attempt,
        sessionCurrent: () =>
            client.auth.currentSession?.user.id == uid &&
            !(client.auth.currentSession?.isExpired ?? true),
      );
    }

    /// After sign-in the AUTHORIZED writable reconcile has run for the uid: an
    /// ordinary scope, the owner-generation repaired, the freeze lifted, the
    /// gate permitting, and nothing deleted.
    Future<void> expectReconciledAfterSignIn(
        BootstrapRunner r, CloudEgressGate gate,
        {required int repairsExpected}) async {
      final scope = r.accountScope.current!;
      expect(scope.uid, uid);
      expect(scope.isLocalRead, isFalse);
      expect(repairs, repairsExpected);
      expect(ConsentAuthority.egressFrozen, isFalse,
          reason: 'tag: ${ConsentAuthority.egressFreezeTag}');
      expect(storage.data['local_data_owner_uid'], uid);
      expect(await gate.permits(), isTrue);
      expect(scope.hasLocalData, isTrue);
      final rows = await scope.database
          .customSelect('SELECT COUNT(*) AS c FROM transactions')
          .getSingle();
      expect(rows.read<int>('c'), 1, reason: 'no data was deleted');
    }

    /// The explicit Cloud enable (what the consent sheet runs) against a realistic
    /// native side: the restrictive publication returns an exact receipt and the
    /// pending-enable protocol is answered. Returns the simulated native side.
    Future<NativeEnableSim> enableCloudEndToEnd(BootstrapRunner r) async {
      final sim = NativeEnableSim(uid: uid)
        ..ownerEpoch = 0
        ..ownerGeneration = 9;
      messenger.setMockMethodCallHandler(channel, sim.handle);
      final db = r.accountScope.current!.database;
      // The user turns Cloud on from Off: the build-56 ON fixture is cleared.
      final repo = DriftUserSettingsRepository(db);
      await repo.saveSettings((await repo.getSettings()).copyWith(
          cloudConsentState: ConsentState.unset,
          aiConsentState: ConsentState.unset));
      storage.data.remove(CloudEgressStore.kSecureKey);
      final egressFile = File(p.join(support.path, CloudEgressStore.kFileName));
      if (egressFile.existsSync()) egressFile.deleteSync();
      final service = CaptureDeviceRegistrationService(
        settingsRepository: DriftUserSettingsRepository(db),
        isIos: () => true,
        isBackendConfigured: () => true,
        isCurrentScope: () => identical(r.accountScope.current?.database, db),
      );
      // The host platform is not iOS: the production hook (the runner's own
      // service) would refuse, so the same publication runs through this one.
      session.configureCaptureOwnerPublish((u, a) =>
          service.publishRestrictiveOwnerDetailed(admissionAuthority: a));
      await service.enableCloud(
          write: ConsentWrite(
              session.captureConsentCapability()!,
              const ConsentChoices(
                  cloud: ConsentState.accepted, ai: ConsentState.accepted)));
      expect(sim.of('publishRestrictiveCaptureOwner'), hasLength(1),
          reason: 'the returning process published its own proof');
      expect(sim.egressState, 'ON');
      expect(await CloudEgressGate.instance.permits(), isTrue);
      return sim;
    }

    int idTokenRequests() => reached
        .where((r) =>
            r.url.path == '/auth/v1/token' &&
            r.url.queryParameters['grant_type'] == 'id_token')
        .length;

    /// Resolved but restrictive: nothing ordinary reaches the transport.
    Future<void> expectResolvedRestrictive(CloudEgressGate gate) async {
      expect(gate.isResolved, isTrue);
      expect(ConsentAuthority.egressFrozen, isTrue);
      expect(await gate.permits(), isFalse);
      final before = reached.length;
      await expectLater(
          Supabase.instance.client.rest.from('transactions').select(),
          throwsA(anything));
      await expectLater(
          gate.runAccountControl(
              AccountControlOp.signIn,
              () =>
                  Supabase.instance.client.rest.from('transactions').select()),
          throwsA(anything));
      expect(reached.length, before, reason: 'no ordinary egress reached it');
    }

    test('1. the expired session disappears during the initial native read',
        () async {
      final gate = await prepare();
      holdNext = Completer<void>();
      heldReached = Completer<void>();
      final r1 = newRunner();
      final running = r1.run();
      await heldReached!.future;
      await loseSession();
      held!.complete();
      await running;
      expect(repairs, 0);
      expect(ConsentAuthority.egressFreezeTag, 'init_lifetime_lost');
      await expectResolvedRestrictive(gate);
      await productionAppleSignIn(gate);
      expect(idTokenRequests(), 1);
      await expectReconciledAfterSignIn(r1, gate, repairsExpected: 1);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test(
        '2. the session disappears after the repair committed, before its '
        'reply', () async {
      final gate = await prepare();
      repairGate = Completer<void>();
      repairReached = Completer<void>();
      final r2 = newRunner();
      final running = r2.run();
      await repairReached!.future;
      expect(mismatch, isFalse, reason: 'the native repair committed');
      await loseSession();
      repairGate!.complete();
      await running;
      expect(repairs, 1);
      expect(ConsentAuthority.egressFreezeTag, 'init_lifetime_lost',
          reason: 'a stale attempt never thaws on the repaired state');
      await expectResolvedRestrictive(gate);
      await productionAppleSignIn(gate);
      expect(idTokenRequests(), 1);
      // The native state was already repaired and reads clean: no second repair.
      await expectReconciledAfterSignIn(r2, gate, repairsExpected: 1);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test(
        '3. the session is already absent: the repair is skipped, sign-in is '
        'not refused as unresolved', () async {
      final gate = await prepare();
      final r = BootstrapRunner(
          debugSdk: BootstrapSdkTestConfig(
        url: url,
        innerStorage: _AbsentStore(),
        innerHttp: MockClient((request) async {
          reached.add(request);
          return http.Response(
              sessionJson(DateTime.now()
                      .add(const Duration(hours: 1))
                      .millisecondsSinceEpoch ~/
                  1000),
              200,
              headers: {'content-type': 'application/json'});
        }),
      ))
        ..captureQueue = queue;
      runners.add(r);
      await r.run();
      expect(repairs, 0);
      await expectResolvedRestrictive(gate);
      await productionAppleSignIn(gate);
      expect(idTokenRequests(), 1);
      await expectReconciledAfterSignIn(r, gate, repairsExpected: 1);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test(
        '4. a local-read grant survives the prior process: a fresh gate '
        'resolves through the dedicated path, no writable initialization',
        () async {
      final gate = await prepare(keepGrant: true);
      final r = newRunner();
      await r.run();
      expect(r.accountScope.current!.isLocalRead, isTrue);
      expect(repairs, 0, reason: 'no repair under a read-only replica');
      expect(queue.publishCalls, 0);
      expect(gate.isResolved, isTrue);
      expect(ConsentAuthority.egressFrozen, isTrue,
          reason: 'the mismatch is uncertain: frozen, tagged');
      expect(ConsentAuthority.egressFreezeTag,
          'startup_uncertain:native:owner_generation_mismatch');
      await expectResolvedRestrictive(gate);
      await productionAppleSignIn(gate);
      expect(idTokenRequests(), 1);
      await expectReconciledAfterSignIn(r, gate, repairsExpected: 1);
    }, timeout: const Timeout(Duration(minutes: 3)));

    // The launch scope is already a WRITABLE scope for the uid, so sign-in's
    // `activate` reuses it without re-initializing; the admission hook
    // (`reconcileReusedScope`) is what repairs and thaws.
    test(
        '5. same-uid writable launch scope: the post-sign-in writable reconcile '
        'repairs and thaws', () async {
      final gate = await prepare();
      holdNext = Completer<void>();
      heldReached = Completer<void>();
      final r5 = newRunner();
      final running = r5.run();
      await heldReached!.future;
      await loseSession();
      held!.complete();
      await running;
      final before = r5.accountScope.current!;
      expect(ConsentAuthority.egressFrozen, isTrue);
      await productionAppleSignIn(gate);
      expect(identical(r5.accountScope.current, before), isTrue,
          reason: 'the scope was reused, not re-initialized');
      await expectReconciledAfterSignIn(r5, gate, repairsExpected: 1);
      // The explicit sign-in's own publication got no receipt from this native
      // mock; the explicit enable publishes the proof it needs and completes.
      await enableCloudEndToEnd(r5);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test(
        '6. returning process, same marker, fresh restored session: no '
        'process lifetime, the explicit enable still publishes and succeeds',
        () async {
      final gate = await prepare();
      mismatch = false; // a consistent native side
      final r6 = BootstrapRunner(
          debugSdk: BootstrapSdkTestConfig(
        url: url,
        innerStorage: _Store(sessionJson(DateTime.now()
                .add(const Duration(hours: 1))
                .millisecondsSinceEpoch ~/
            1000)),
        innerHttp: MockClient((request) async {
          reached.add(request);
          return http.Response('{}', 200);
        }),
      ))
        ..captureQueue = queue;
      runners.add(r6);
      await r6.run();
      // An automatic fresh-session admission of the published scope (resume /
      // token refresh) is what issues the returning user's capability.
      await session.bindSupabaseAuth(Supabase.instance.client);
      expect(r6.accountScope.current!.uid, uid);
      expect(ConsentAuthority.egressFrozen, isFalse);
      expect(session.captureConsentCapability(), isNotNull,
          reason: 'the automatic admission issued a capability');
      await enableCloudEndToEnd(r6);
      expect(gate.isResolved, isTrue);
    }, timeout: const Timeout(Duration(minutes: 3)));
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

class _AbsentStore extends LocalStorage {
  @override
  Future<void> initialize() async {}
  @override
  Future<bool> hasAccessToken() async => false;
  @override
  Future<String?> accessToken() async => null;
  @override
  Future<void> removePersistedSession() async {}
  @override
  Future<void> persistSession(String persistSessionString) async {}
}
