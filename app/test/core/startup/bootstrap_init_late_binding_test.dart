// ignore_for_file: unused_import, unused_element, unused_field, unused_element_parameter, unused_local_variable

// One failing real-SDK initialization per file: gotrue leaves a half-built,
// undisposable singleton after a failed `Supabase.initialize`.
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
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/core/session/capture_queue.dart';
import 'package:money_companion/core/session/local_read_authority.dart';
import 'package:money_companion/core/session/remove_data_flow.dart';
import 'package:money_companion/core/startup/bootstrap_runner.dart';
import 'package:money_companion/data/db/database_access_broker.dart';
import 'package:money_companion/data/db/replica_store.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../session/f2_fixture.dart';
import '../session/recording_secure_storage.dart';

// O-LC-1 (Astra R6) — storage-initialization / read failures during the REAL
// `Supabase.initialize` (the production wiring: observing store + gated
// transport, only the inner store and transport are supplied by the test) are
// connected to the process lock and the durable denial BEFORE the startup
// failure is returned, and a failure the SDK's unawaited recovery meets later is
// handed to the session's denial without any fixed delay. Every effect is
// observed as an attempt.

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
    await first.accountScope.detach();
    first.accountScope.dispose();
    runners.remove(first);
    session.debugResetAdmissionState();
    session.configureRemoveData(null);
    session.configureAccountScope(null);
  }


  String sessionJson({int? exp}) => jsonEncode({
        'access_token': _jwt(uid, exp ?? 1),
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

  Future<LocalReadGrantRecord?> grant() =>
      LocalReadAuthority(store: SecureLocalReadStore()).peekRecord();

  /// The production `Supabase.initialize` wiring over a scripted inner store.
  BootstrapRunner sdkRunner(_Store store, {Future<void> Function()? before}) {
    final runner = BootstrapRunner(
        debugSdk: BootstrapSdkTestConfig(
          url: _url,
          innerStorage: store,
          innerHttp: MockClient((request) async {
            httpRequests++;
            return http.Response('{}', 200);
          }),
          beforeInitialize: before,
        ))
      ..captureQueue = queue;
    runners.add(runner);
    return runner;
  }

  tearDown(() async {
    try {
      if (Supabase.instance.isInitialized) await Supabase.instance.dispose();
    } catch (_) {
      // A failed SDK initialization leaves a half-built singleton: one failing
      // initialization per test file.
    }
    CloudEgressGate.instance = CloudEgressGate();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    CloudEgressGate.instance = CloudEgressGate();
    httpRequests = 0;
  });

  /// An account with a committed grant, then a process that died with the
  /// replica `active` (the shape every case below starts from).
  Future<void> committedGrant() async {
    await accountThenKill();
    expect((await grant())!.state, LocalReadGrantState.committed);
  }

  Future<void> writeSuccessorGrant(String forUid, String op) async {
    final old = await grant();
    await SecureLocalReadStore().write(LocalReadGrantRecord(
      state: LocalReadGrantState.committed,
      operationId: op,
      uid: forUid,
      replicaId: old!.replicaId,
    ).encode());
  }

  Future<BootstrapRunner> heldRecovery(Completer<void> gate) async {
    await committedGrant();
    final runner = sdkRunner(_Store(
        session: sessionJson(), recoverySession: '{not json', recoveryGate: gate));
    await runner.run();
    expect(session.localReadActive, isTrue);
    expect(runner.accountScope.current!.isLocalRead, isTrue);
    return runner;
  }

  Future<void> lateArrives(BootstrapRunner runner, Completer<void> gate) async {
    gate.complete();
    await _until(() => runner.debugAuthInitEvents.unknownProvenance);
    await runner.debugProvenanceDenials;
  }

  group('O-LC-1a late classification is bound to its originating startup', () {
    test('fresh same-UID admission: the successor grant and lock survive',
        () async {
      final gate = Completer<void>();
      final runner = await heldRecovery(gate);
      await session.completeOnboarding(
          method: 'google', email: '$uid@example.com', userId: uid);
      expect(runner.accountScope.current!.isLocalRead, isFalse);
      await writeSuccessorGrant(uid, 'successor-op-same');
      await lateArrives(runner, gate);
      final g = (await grant())!;
      expect(g.operationId, 'successor-op-same');
      expect(g.state, LocalReadGrantState.committed,
          reason: 'the successor grant is not the originating uncertain one');
      expect(session.debugLocalReadLocked, isFalse,
          reason: 'the process lock is not set against the successor');
      expect(session.localReadCleanupIncomplete, isFalse);
      expect(runner.accountScope.activeUid, uid);
    });

    test('different-UID admission: the successor grant and lock survive',
        () async {
      final gate = Completer<void>();
      final runner = await heldRecovery(gate);
      await session.completeOnboarding(
          method: 'google', email: 'uid-other@example.com', userId: 'uid-other');
      await writeSuccessorGrant('uid-other', 'successor-op-other');
      await lateArrives(runner, gate);
      final g = (await grant())!;
      expect(g.operationId, 'successor-op-other');
      expect(g.uid, 'uid-other');
      expect(g.state, LocalReadGrantState.committed);
      expect(session.debugLocalReadLocked, isFalse);
      expect(runner.accountScope.activeUid, 'uid-other');
    });

    test('logout: the originating grant stays denied, nothing unlocks',
        () async {
      final gate = Completer<void>();
      final runner = await heldRecovery(gate);
      await session.signOut();
      expect((await grant())!.state, LocalReadGrantState.blocked);
      await lateArrives(runner, gate);
      expect((await grant())!.state, LocalReadGrantState.blocked);
      expect(session.debugLocalReadLocked, isTrue);
      expect(session.localReadActive, isFalse);
    });

    test('logout then independent admission: late classification leaves it',
        () async {
      final gate = Completer<void>();
      final runner = await heldRecovery(gate);
      await session.signOut();
      await session.completeOnboarding(
          method: 'google', email: 'uid-other@example.com', userId: 'uid-other');
      await writeSuccessorGrant('uid-other', 'successor-op-after-logout');
      await lateArrives(runner, gate);
      final g = (await grant())!;
      expect(g.operationId, 'successor-op-after-logout');
      expect(g.state, LocalReadGrantState.committed);
    });

    test('removal: the originating grant stays denied', () async {
      final gate = Completer<void>();
      final runner = await heldRecovery(gate);
      await session.removeDataFromDevice();
      await lateArrives(runner, gate);
      expect((await grant())!.state, LocalReadGrantState.blocked);
      expect(session.localReadActive, isFalse);
    });

    test(
        'successor lifecycle begun but scope not yet replaced: the startup '
        'scope is still retracted and its grant denied, without the lock',
        () async {
      final gate = Completer<void>();
      final runner = await heldRecovery(gate);
      final origin = (await grant())!;
      session.debugBeginSuccessorLifecycle();
      await lateArrives(runner, gate);
      expect(session.localReadActive, isFalse,
          reason: 'the originating local-read scope is retracted');
      expect(runner.accountScope.current?.isLocalRead ?? false, isFalse);
      final g = (await grant())!;
      expect(g.operationId == origin.operationId, isFalse,
          reason: 'the stored record was rewritten as a denial');
      expect(g.state, LocalReadGrantState.blocked);
      expect(session.debugLocalReadLocked, isFalse,
          reason: 'the lock is not set against a successor lifecycle');
    });

    test('no successor: the existing lock and denial are unchanged', () async {
      final gate = Completer<void>();
      final runner = await heldRecovery(gate);
      await lateArrives(runner, gate);
      expect(session.debugLocalReadLocked, isTrue);
      expect((await grant())!.state, LocalReadGrantState.blocked);
      expect(session.localReadActive, isFalse);
    });
  });
}

const _url = 'https://abcdefghij.supabase.co';

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('condition never held');
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

/// A scripted inner session store: the first load answers [session]; the SDK's
/// later recovery load waits on [recoveryGate] and answers [recoverySession].
class _Store extends LocalStorage {
  _Store({
    this.failInitialize = false,
    this.failHas = false,
    this.failAccess = false,
    this.session,
    this.recoverySession,
    this.recoveryGate,
  });
  final bool failInitialize;
  final bool failHas;
  final bool failAccess;
  final String? session;
  final String? recoverySession;
  final Completer<void>? recoveryGate;
  bool recoveryDone = false;
  int _has = 0;
  int _access = 0;

  @override
  Future<void> initialize() async {
    if (failInitialize) throw StateError('storage initialize failed');
  }

  @override
  Future<bool> hasAccessToken() async {
    if (failHas) throw StateError('storage unreadable');
    if (++_has >= 2) await recoveryGate?.future;
    return session != null;
  }

  @override
  Future<String?> accessToken() async {
    if (failAccess) throw StateError('storage unreadable');
    if (++_access >= 2) {
      await recoveryGate?.future;
      recoveryDone = true;
      return recoverySession ?? session;
    }
    return session;
  }

  @override
  Future<void> removePersistedSession() async {}
  @override
  Future<void> persistSession(String persistSessionString) async {}
}
