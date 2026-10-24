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
import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../session/f2_fixture.dart';
import '../session/recording_secure_storage.dart';

// O-H2 — the REAL BootstrapRunner.run(): after removal-first handling and BEFORE
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
    await first.accountScope.detach();
    first.accountScope.dispose();
    runners.remove(first);
    session.debugResetAdmissionState();
    session.configureRemoveData(null);
    session.configureAccountScope(null);
  }

  Future<int> txCount(BootstrapRunner r) async => (await r
          .accountScope.current!.database
          .customSelect('SELECT COUNT(*) AS c FROM transactions;')
          .getSingle())
      .read<int>('c');

  List<String> forbiddenWrites(int from) => [
        for (final a in storage.attempts.skip(from))
          if (a.startsWith('write:qirsh.db_key.') ||
              a.startsWith('write:qirsh.device_salt') ||
              a.startsWith('write:qirsh.replicas.v1=') ||
              a.startsWith('write:${SecureLocalReadStore.storageKey}') ||
              a.startsWith('write:local_data_owner') ||
              a.startsWith('delete:'))
            a,
      ];

  for (final mode in ['expired', 'absent']) {
    test('$mode SDK on cold start restores the same replica read-only, before '
        'any recovery, adoption or service init', () async {
      await accountThenKill();
      final legacy = File(p.join(support.path, 'money_companion.sqlite'))
        ..writeAsBytesSync(List<int>.filled(64, 7));
      final events = <String>[];
      final from = storage.attempts.length;
      final holdersBefore =
          DatabaseAccessBroker.createInert().openHolders;
      final runner = await boot(
          mode == 'expired' ? await expiredClient() : absentClient(),
          events: events.add);

      final scope = runner.accountScope.current!;
      expect(scope.isLocalRead, isTrue);
      expect(scope.uid, uid);
      expect(scope.database.isReadOnly, isTrue);
      expect(session.localReadActive, isTrue);
      expect(session.status, isNot(SessionStatus.authenticated),
          reason: 'an expired or absent token is never promoted');
      expect(await txCount(runner), 1);

      expect(events.where((e) => e.startsWith('adoption:')), isEmpty);
      expect(events, isNot(contains('opener')));
      expect(events, isNot(contains('liveness')));
      expect(events, isNot(contains('native-open')));
      expect(legacy.existsSync(), isTrue,
          reason: 'legacy adoption/quarantine is deferred');
      expect(forbiddenWrites(from), isEmpty);
      expect(_SpyNotifications.initCalls, 0,
          reason: 'no notification service init in local-read');
      expect(DatabaseAccessBroker.createInert().openHolders, holdersBefore + 1,
          reason: 'the read-only candidate is tracked by the coordinator');
    });
  }

  test('without a grant an expired SDK takes the ordinary path', () async {
    await accountThenKill();
    storage.data.remove(SecureLocalReadStore.storageKey);
    final runner = await boot(await expiredClient());
    expect(runner.accountScope.current!.isLocalRead, isFalse);
    expect(session.localReadActive, isFalse);
  });

  test('a fresh SDK session takes the ordinary writable path', () async {
    await accountThenKill();
    final runner = await boot(await F2Fixture.liveClient(uid));
    expect(runner.accountScope.current!.isLocalRead, isFalse);
    expect(session.localReadActive, isFalse);
  });

  test('a pending removal blocks local-read: removal state is handled first',
      () async {
    await accountThenKill();
    final replicas = ReplicaStore(appSupportDirectory: support.path);
    final hash = await replicas.uidHash(uid);
    storage.data[RemoveDataFlow.barrierKey] =
        jsonEncode({'uid': uid, 'uidHash': hash, 'revoke': true});
    final runner = await boot(await expiredClient());
    expect(runner.accountScope.current?.isLocalRead ?? false, isFalse);
    expect(session.localReadActive, isFalse);
    expect(storage.data[RemoveDataFlow.revokedKey] ?? '', contains(uid));
  });

  // ------------------------------------------------------------------ D2
  //
  // Astra D2: auth events the SDK emits DURING initialization (before ordinary
  // binding) are observed and buffered. A buffered signedOut/userDeleted, or any
  // unknown provenance, keeps the launch restrictive and establishes a durable
  // denial; only verified plain absence / ordinary expiry restores local read.

  // ignore: invalid_use_of_internal_member
  void emit(SupabaseClient c, AuthChangeEvent e) => c.auth.notifyAllSubscribers(e);

  Future<LocalReadGrantRecord?> grant() =>
      LocalReadAuthority(store: SecureLocalReadStore()).peekRecord();

  for (final mode in ['expired', 'absent']) {
    for (final event in [AuthChangeEvent.signedOut, AuthChangeEvent.userDeleted]) {
      test('D2: $event emitted during SDK init ($mode session) is restrictive: '
          'no local-read publication and a durable denial', () async {
        await accountThenKill();
        expect((await grant())!.state, LocalReadGrantState.committed);
        final client =
            mode == 'expired' ? await expiredClient() : absentClient();
        final runner = await boot(client, initialize: (c) async {
          emit(c, event);
          await Future<void>.delayed(Duration.zero);
        });
        expect(runner.accountScope.current!.isLocalRead, isFalse);
        expect(session.localReadActive, isFalse);
        expect(session.status, isNot(SessionStatus.authenticated));
        expect((await grant())!.state, LocalReadGrantState.blocked,
            reason: 'unknown provenance establishes the durable denial');
      });
    }
  }

  test('D2: a loss event arriving after init returns but before ordinary '
      'binding still ends restrictive', () async {
    await accountThenKill();
    final runner = await boot(await expiredClient(), initialize: (c) async {
      unawaited(Future<void>.delayed(
          const Duration(milliseconds: 5), () => emit(c, AuthChangeEvent.signedOut)));
    });
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await session.debugLocalReadIdle;
    expect(session.localReadActive, isFalse);
    expect((await grant())!.state, LocalReadGrantState.blocked);
    expect(runner.accountScope.current!.isLocalRead, isFalse);
  });

  // Astra R12 — unknown persisted-state provenance (unreadable, malformed or
  // inconsistently loaded) behaves like an observed loss: restoration is denied
  // and the denial is durable. Verified empty / valid expired state (controls
  // above and the real-SDK cases in auth_init_provenance_test.dart) restores.
  for (final mode in ['expired', 'absent']) {
    for (final reason in [
      'malformed_session',
      'inconsistent_storage',
      'storage_unreadable'
    ]) {
      test('R12: $mode SDK, $reason during init is restrictive: no local-read '
          'publication and a durable denial', () async {
        await accountThenKill();
        final client =
            mode == 'expired' ? await expiredClient() : absentClient();
        late BootstrapRunner runner;
        runner = BootstrapRunner(
            debugAuthClient: client,
            debugAuthInitialize: (c) async {
              emit(c, AuthChangeEvent.initialSession);
              runner.debugAuthInitEvents.markUnknownProvenance(reason);
              await Future<void>.delayed(Duration.zero);
            })
          ..captureQueue = queue;
        runners.add(runner);
        await runner.run();
        expect(runner.accountScope.current!.isLocalRead, isFalse);
        expect(session.localReadActive, isFalse);
        expect((await grant())!.state, LocalReadGrantState.blocked,
            reason: 'unknown provenance establishes the durable denial');
      });
    }
  }

  // Astra R10.1 — the provenance fence reaches publication. A restrictive loss
  // delivered at ANY await of the restoration must end in ZERO publication (the
  // local-read scope is never visible, not even briefly), not in a later
  // correction by the replay after binding.
  for (final mode in ['expired', 'absent']) {
    for (final point in ['record_read', 'exclusion_drained', 'restore_returned']) {
      test('R10.1: $mode SDK, loss delivered at $point publishes nothing',
          () async {
        await accountThenKill();
        expect((await grant())!.state, LocalReadGrantState.committed);
        final client =
            mode == 'expired' ? await expiredClient() : absentClient();
        var everLocalRead = false;
        void watch() {
          if (session.localReadActive) everLocalRead = true;
        }

        session.addListener(watch);
        addTearDown(() => session.removeListener(watch));
        final seen = <String>[];
        session.debugLocalReadAwaitPoint = (name) async {
          seen.add(name);
          if (name != point) return;
          emit(client, AuthChangeEvent.signedOut);
          await Future<void>.delayed(Duration.zero);
        };
        addTearDown(() => session.debugLocalReadAwaitPoint = null);
        final runner = await boot(client, initialize: (c) async {
          emit(c, AuthChangeEvent.initialSession);
          await Future<void>.delayed(Duration.zero);
        });
        expect(seen, contains(point), reason: 'the restoration reached $point');
        expect(everLocalRead, isFalse,
            reason: 'a loss before publication must publish nothing');
        expect(runner.accountScope.current!.isLocalRead, isFalse);
        expect(session.localReadActive, isFalse);
        expect((await grant())!.state, LocalReadGrantState.blocked,
            reason: 'the loss establishes the durable denial');
      });
    }
  }

  for (final mode in ['expired', 'absent']) {
    test('D2 control: $mode SDK with only benign init events still restores '
        'local read', () async {
      await accountThenKill();
      final client = mode == 'expired' ? await expiredClient() : absentClient();
      final runner = await boot(client, initialize: (c) async {
        emit(c, AuthChangeEvent.initialSession);
        await Future<void>.delayed(Duration.zero);
      });
      expect(runner.accountScope.current!.isLocalRead, isTrue);
      expect(session.localReadActive, isTrue);
      expect((await grant())!.state, LocalReadGrantState.committed);
    });
  }

  // ------------------------------------------------------------------ D1
  //
  // Astra D1: the startup order is removal-first, then SDK initialization, then
  // the local-read decision. On the local-read path NOTHING ordinary runs: no
  // recovery, adoption or retired purge, no notification service, metrics,
  // housekeeping or native publication, and no network attempt of any kind.

  for (final mode in ['expired', 'absent']) {
    test('D1: $mode local-read launch runs removal first and skips every '
        'ordinary / networked / native-publishing step', () async {
      await accountThenKill();
      // A retired replica copy past its retention: an ordinary launch would purge
      // it (delete dir + key, rewrite the registry).
      final replicas = ReplicaStore(appSupportDirectory: support.path);
      final hash = await replicas.uidHash(uid);
      final retiredDir =
          Directory(p.join(support.path, 'replicas', '$hash.old'))
            ..createSync(recursive: true);
      File(p.join(retiredDir.path, 'qirsh.sqlite')).writeAsBytesSync([1, 2, 3]);
      storage.data['qirsh.db_key.$hash.old'] = 'retired-key';
      final registry = jsonDecode(storage.data[ReplicaStore.registryKey]!)
          as Map<String, Object?>;
      (registry[hash]! as Map<String, Object?>)['retiredAt'] = DateTime.now()
          .toUtc()
          .subtract(const Duration(days: 60))
          .toIso8601String();
      storage.data[ReplicaStore.registryKey] = jsonEncode(registry);
      final registryBefore = storage.data[ReplicaStore.registryKey];

      final steps = <String>[];
      final oldPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null && message.startsWith('[Bootstrap] ')) {
          steps.add(message);
        }
      };
      final nativeCalls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('money_companion/native_capture'),
              (call) async {
        nativeCalls.add(call.method);
        throw MissingPluginException();
      });
      final client = mode == 'expired' ? await expiredClient() : absentClient();
      final publishBefore = queue.publishCalls;
      final clearBefore = queue.clearCalls;
      final httpBefore = httpRequests;
      final from = storage.attempts.length;
      _CountingHttpOverrides.created = 0;
      final oldOverrides = HttpOverrides.current;
      HttpOverrides.global = _CountingHttpOverrides();
      final BootstrapRunner runner;
      try {
        runner = await boot(client, initialize: (c) async {
          emit(c, AuthChangeEvent.initialSession);
          await Future<void>.delayed(Duration.zero);
        });
        // Deferred (fire-and-forget) work would start right after the return.
        await Future<void>.delayed(const Duration(milliseconds: 300));
      } finally {
        HttpOverrides.global = oldOverrides;
        debugPrint = oldPrint;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
                const MethodChannel('money_companion/native_capture'), null);
      }
      expect(runner.accountScope.current!.isLocalRead, isTrue);

      int at(String step) =>
          steps.indexWhere((m) => m == '[Bootstrap] $step start');
      expect(at('removal_recovery'), greaterThanOrEqualTo(0));
      expect(at('supabase_init'), greaterThan(at('removal_recovery')));
      expect(at('local_read_decision'), greaterThan(at('supabase_init')));
      for (final ordinary in [
        'replica_recovery',
        'notifications_init',
        'database_open',
        'has_local_data',
        'planning_cutover_state',
        'seed_catalog',
        'feature_flags_init',
        'capture_registration',
        'db_key_ref_cleanup',
        'goal_autosaves',
      ]) {
        expect(at(ordinary), -1, reason: '$ordinary must not run in local read');
      }

      expect(httpRequests, httpBefore, reason: 'zero requests left the transport');
      expect(_CountingHttpOverrides.created, 0,
          reason: 'no dart:io HttpClient at all');
      expect(queue.publishCalls, publishBefore,
          reason: 'no capture-owner publication');
      expect(queue.clearCalls, clearBefore);
      expect(nativeCalls.where((c) => c.toLowerCase().contains('publish')),
          isEmpty,
          reason: 'no native publication: $nativeCalls');
      expect(_SpyNotifications.initCalls, 0);
      expect(forbiddenWrites(from), isEmpty);
      expect(storage.data[ReplicaStore.registryKey], registryBefore,
          reason: 'the retired purge did not rewrite the registry');
      expect(retiredDir.existsSync(), isTrue,
          reason: 'the retired purge is deferred');
      expect(storage.data['qirsh.db_key.$hash.old'], 'retired-key');
    });
  }

  test('D1: removal runs first for an ABSENT sdk session too: a pending removal '
      'blocks local read before SDK initialization is even consulted', () async {
    await accountThenKill();
    final replicas = ReplicaStore(appSupportDirectory: support.path);
    final hash = await replicas.uidHash(uid);
    storage.data[RemoveDataFlow.barrierKey] =
        jsonEncode({'uid': uid, 'uidHash': hash, 'revoke': true});
    final runner = await boot(absentClient());
    expect(runner.accountScope.current?.isLocalRead ?? false, isFalse);
    expect(session.localReadActive, isFalse);
    expect(storage.data[RemoveDataFlow.revokedKey] ?? '', contains(uid));
  });
}
