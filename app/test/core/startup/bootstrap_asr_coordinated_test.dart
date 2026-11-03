// ignore_for_file: depend_on_referenced_packages

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_local_notifications_platform_interface/flutter_local_notifications_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/core/auth/auth_coordinator.dart';
import 'package:money_companion/core/auth/refresh_transport.dart';
import 'package:money_companion/core/auth/session_files.dart';
import 'package:money_companion/core/auth/session_record.dart';
import 'package:money_companion/core/auth/session_store.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/core/session/capture_queue.dart';
import 'package:money_companion/core/startup/bootstrap_runner.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth/store_fakes.dart';
import '../session/recording_secure_storage.dart';

/// ASR v7.2 WP5: the REAL `Supabase.initialize` wiring in coordinated mode —
/// the session store is loaded before the SDK exists (§6.7/§6.8), the one-shot
/// storage serves exactly the initialize pair (§3.2), persistence callbacks are
/// no-ops (I4) and an upgraded install keeps its session (§6.6).

const _url = 'https://abcdefghij.supabase.co';
const _uid = 'uid-asr-a';

class _SpyNotifications extends FlutterLocalNotificationsPlatform {
  @override
  Future<NotificationAppLaunchDetails?>
      getNotificationAppLaunchDetails() async => null;
}

class _Queue implements CaptureQueueBridge {
  @override
  Future<CaptureRemovalBarrierRead> getCaptureRemovalBarrier() async =>
      const CaptureRemovalBarrierRead.absent();
  @override
  Future<void> beginCaptureRemoval(String uid) async {}
  @override
  Future<void> finishCaptureRemoval(String uid) async {}
  @override
  Future<int> captureOwnerEpoch() async => 0;
  @override
  Future<bool> clearCaptureOwner({bool clearHint = false}) async => true;
  @override
  Future<void> publishCaptureOwner({
    required String uid,
    required bool cloud,
    required bool ai,
    required int version,
    required int expectedEpoch,
    int? transitionGeneration,
  }) async {}
}

class _NoChannel implements RefreshChannel {
  @override
  bool get sent => false;
  @override
  Future<void> open() async => throw StateError('no network in this test');
  @override
  Future<RefreshHttpResult> send(String refreshToken) =>
      throw StateError('no network in this test');
  @override
  void cancel() {}
  @override
  void close() {}
  @override
  Future<void> quiesced() async {}
}

bool _sdkInitialized() {
  try {
    return Supabase.instance.isInitialized;
  } catch (_) {
    return false;
  }
}

String _legacySession({required int exp}) {
  String b64(Object o) =>
      base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  final token = '${b64({'alg': 'none'})}.${b64({
        'sub': _uid,
        'exp': exp,
        'iss': '$_url/auth/v1'
      })}.s';
  return jsonEncode({
    'access_token': token,
    'token_type': 'bearer',
    'expires_in': 3600,
    'refresh_token': 'legacy-refresh',
    'user': {
      'id': _uid,
      'app_metadata': <String, Object>{},
      'user_metadata': <String, Object>{},
      'aud': 'authenticated',
      'created_at': '2024-01-01T00:00:00.000Z',
    },
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory support;
  late FakeKeychain keychain;
  late FakeLegacy legacy;
  late List<http.BaseRequest> requests;
  final coordinators = <AuthCoordinator>[];
  Timer? frames;

  setUp(() async {
    support = Directory.systemTemp.createTempSync('bootstrap_asr_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => support.path,
    );
    RecordingSecureStorage().install();
    FlutterLocalNotificationsPlatform.instance = _SpyNotifications();
    SharedPreferences.setMockInitialValues({});
    CloudEgressGate.instance = CloudEgressGate();
    AppSession.instance.debugResetAdmissionState();
    AppSession.instance.configureRemoveData(null);
    AppSession.instance.configureAccountScope(null);
    AppSession.instance.configureLocalRead(null);
    await AppSession.instance.wipeAndReset();
    keychain = FakeKeychain();
    legacy = FakeLegacy();
    requests = [];
    final binding = TestWidgetsFlutterBinding.instance;
    frames = Timer.periodic(const Duration(milliseconds: 20), (_) {
      binding.scheduleFrame();
      binding.handleBeginFrame(Duration.zero);
      binding.handleDrawFrame();
    });
  });

  tearDown(() async {
    frames?.cancel();
    for (final c in coordinators) {
      c.dispose();
    }
    coordinators.clear();
    AuthCoordinator.active = null;
    try {
      if (Supabase.instance.isInitialized) await Supabase.instance.dispose();
    } catch (_) {}
    CloudEgressGate.instance = CloudEgressGate();
    AppSession.instance.configureRemoveData(null);
    AppSession.instance.configureAccountScope(null);
    AppSession.instance.configureLocalRead(null);
    AppSession.instance.configureCaptureOwnerClear(null);
    support.deleteSync(recursive: true);
  });

  SessionStore newStore() => SessionStore(
        keychain: keychain,
        files: SessionFiles(support),
        origin: Uri.parse(_url),
        legacy: legacy,
        localInstallDataPresent: () async => true,
      );

  BootstrapRunner runner() => BootstrapRunner(
          debugSdk: BootstrapSdkTestConfig(
        url: _url,
        innerHttp: MockClient((request) async {
          requests.add(request);
          return http.Response('{}', 200);
        }),
        authCoordinator: () async {
          final c = AuthCoordinator(
              store: newStore(),
              gate: CloudEgressGate.instance,
              channelFactory: _NoChannel.new);
          coordinators.add(c);
          return c;
        },
      ))
        ..captureQueue = _Queue();

  test(
      'protected data locked → AuthDeferred: no initialize, no latch, nothing '
      'published; available → the retry initializes', () async {
    BootstrapRunner.debugResetSdkInitializationLatch();
    keychain.protectedData = false;
    final r = runner();
    await expectLater(r.run(), throwsA(isA<BootstrapAuthDeferred>()));
    expect(_sdkInitialized(), isFalse);
    expect(AuthCoordinator.active, isNull);
    expect(r.lastStep, 'supabase_init');
    keychain.protectedData = true;
    await r.run();
    expect(_sdkInitialized(), isTrue,
        reason: "the deferral did not latch: the same process initializes");
    expect(AuthCoordinator.active, isNotNull);
    expect(requests, isEmpty);
  });

  test(
      'upgrade: the legacy SDK session is imported (ordinary) and served once; '
      'the lazy recovery read finds nothing; persistence is a no-op', () async {
    BootstrapRunner.debugResetSdkInitializationLatch();
    final exp = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
    legacy.value = _legacySession(exp: exp);
    await runner().run();
    final coord = AuthCoordinator.active!;
    final auth = Supabase.instance.client.auth;
    expect(auth.currentSession?.user.id, _uid);
    final c = coord.store.committed!;
    expect(c.owner, _uid);
    expect(c.admission, AdmissionDisposition.ordinary);
    expect(coord.sdkBaseline, c.digest);
    expect(coord.sdkDigest, c.digest);
    expect(coord.automaticAdmissionDenial(), isNull);
    expect(legacy.value, isNull, reason: 'legacy cleanup ran');
    // The init event was tagged by the coordinator.
    final itemBefore = keychain.items[coord.store.itemKey];
    // The SDK's own refresh never reaches the transport.
    await expectLater(auth.refreshSession(), throwsA(anything));
    expect(
        requests.where((r) => r.url.path.endsWith('/auth/v1/token')), isEmpty);
    expect(keychain.items[coord.store.itemKey], itemBefore,
        reason: 'SDK callbacks never write the store');
    // A second process loads the same committed record.
    final reloaded = newStore();
    expect((await reloaded.load()).loadClass, LoadClass.valid);
  });

  test('a malformed record takes the provenance restriction', () async {
    BootstrapRunner.debugResetSdkInitializationLatch();
    final probe = newStore();
    await probe.load();
    keychain.items[probe.itemKey] = '{"v":2}';
    final r = runner();
    try {
      await r.run();
    } catch (_) {}
    expect(r.debugAuthInitEvents.unknownProvenance, isTrue);
    expect(Supabase.instance.client.auth.currentSession, isNull);
  });

  test('logout removes the record durably (next launch is verified empty)',
      () async {
    BootstrapRunner.debugResetSdkInitializationLatch();
    final exp = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
    legacy.value = _legacySession(exp: exp);
    await runner().run();
    final auth = Supabase.instance.client.auth;
    expect(auth.currentSession, isNotNull);
    await AuthCoordinator.logout(auth);
    expect(auth.currentSession, isNull);
    expect(AuthCoordinator.active!.store.committed, isNull);
    final next = newStore();
    expect((await next.load()).loadClass, LoadClass.verifiedEmpty);
  });
}
