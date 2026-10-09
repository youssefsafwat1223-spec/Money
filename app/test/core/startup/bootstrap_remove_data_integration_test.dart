import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show debugPrint;
// ignore: depend_on_referenced_packages
import 'package:flutter_local_notifications_platform_interface/flutter_local_notifications_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/core/session/capture_queue.dart';
import 'package:money_companion/core/session/remove_data_flow.dart';
import 'package:money_companion/core/startup/bootstrap_runner.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/replica_store.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';
import 'package:path/path.dart' as p;

import '../session/f2_fixture.dart';
import '../session/recording_secure_storage.dart';

// F2 round 2 (R7) — the REAL BootstrapRunner.run() over injected platform
// channels, storage and auth client: the production startup orchestration
// decides what is adopted, bound, opened and admitted.

class _NoNotifications extends FlutterLocalNotificationsPlatform {
  @override
  Future<NotificationAppLaunchDetails?>
      getNotificationAppLaunchDetails() async => null;
}

class _Queue implements CaptureQueueBridge {
  CaptureRemovalBarrierRead barrier = const CaptureRemovalBarrierRead.absent();
  final calls = <String>[];
  @override
  Future<CaptureRemovalBarrierRead> getCaptureRemovalBarrier() async {
    calls.add('get');
    return barrier;
  }

  @override
  Future<void> beginCaptureRemoval(String uid) async => calls.add('begin:$uid');
  @override
  Future<void> finishCaptureRemoval(String uid) async {
    calls.add('finish:$uid');
    barrier = const CaptureRemovalBarrierRead.absent();
  }

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory support;
  late RecordingSecureStorage storage;
  late _Queue queue;
  final session = AppSession.instance;
  final runners = <BootstrapRunner>[];
  Timer? frames;

  setUp(() async {
    support = Directory.systemTemp.createTempSync('bootstrap_it_');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => support.path,
    );
    storage = RecordingSecureStorage().install();
    FlutterLocalNotificationsPlatform.instance = _NoNotifications();
    queue = _Queue();
    session.debugResetAdmissionState();
    session.configureRemoveData(null);
    session.configureAccountScope(null);
    await session.wipeAndReset();
    // Production waits for a frame after withdrawing a scope
    // (`WidgetsBinding.instance.endOfFrame`); a non-widget test has none, so
    // frames are driven by hand.
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
    frames?.cancel();
    runners.clear();
    session.configureRemoveData(null);
    session.configureAccountScope(null);
    session.configureCaptureOwnerClear(null);
    support.deleteSync(recursive: true);
  });

  Future<BootstrapRunner> boot({String? staleSessionOf}) async {
    final client = staleSessionOf == null
        ? null
        : await F2Fixture.liveClient(staleSessionOf);
    final runner = BootstrapRunner(debugAuthClient: client)
      ..captureQueue = queue;
    runners.add(runner);
    await runner.run();
    return runner;
  }

  Directory replicas() => Directory(p.join(support.path, 'replicas'));
  List<String> replicaDirs() => replicas().existsSync()
      ? [
          for (final e in replicas().listSync())
            if (e is Directory && !p.basename(e.path).startsWith('_'))
              p.basename(e.path),
        ]
      : [];
  List<String> keyWrites(int from) => [
        for (final a in storage.attempts.skip(from))
          if (a.startsWith('write:qirsh.db_key.')) a,
      ];
  List<String> admissionWrites(int from) => [
        for (final a in storage.attempts.skip(from))
          if (a.startsWith('write:$kMarkerKey=') ||
              a.startsWith('write:$kGenerationKey=') ||
              a.startsWith('write:qirsh.db_key.') ||
              (a.startsWith('write:qirsh.replicas.v1=') &&
                  a != 'write:qirsh.replicas.v1={}'))
            a,
      ];

  Future<void> signIn(String uid) => session.completeOnboarding(
      method: 'google', email: '$uid@example.com', userId: uid);

  test(
      'Stage2 real ended child lease permits pending removal on actual restart',
      () async {
    final first = await boot(staleSessionOf: 'uid-x');
    await signIn('uid-x');
    final replicasStore = ReplicaStore(appSupportDirectory: support.path);
    final location = await replicasStore.locationFor('uid-x');
    final hash = await replicasStore.uidHash('uid-x');
    await first.accountScope.lock();
    AppDatabase.dropProcessLiveness(location);
    final helper = File(p.join(support.path, 'ended_helper.dart'))
      ..writeAsStringSync(r'''import 'dart:io';
void main(List<String> a) {
  final lock = File(a[0]).openSync(mode: FileMode.write);
  lock.lockSync(FileLock.exclusive);
  Directory(a[1]).createSync();
  File('${a[1]}/ended.lease').writeAsStringSync('child-token\n$pid\nchild-instance');
  exit(0);
}
''');
    final child = await Process.run(
        'dart', [helper.path, location.plockPath, location.leaseDir]);
    expect(child.exitCode, 0, reason: '${child.stderr}');
    expect(File(p.join(location.leaseDir, 'ended.lease')).existsSync(), isTrue);
    storage.data[RemoveDataFlow.barrierKey] =
        jsonEncode({'uid': 'uid-x', 'uidHash': hash, 'revoke': true});
    session.debugResetAdmissionState();
    session.configureRemoveData(null);
    session.configureAccountScope(null);
    final from = storage.attempts.length;
    final restarted = await boot(staleSessionOf: 'uid-x');
    expect(storage.data.containsKey(RemoveDataFlow.barrierKey), isFalse);
    expect(storage.data[RemoveDataFlow.revokedKey], contains('uid-x'));
    expect(Directory(location.directory).existsSync(), isFalse);
    expect(storage.data.containsKey(location.keyName), isFalse);
    expect(restarted.accountScope.activeUid, isNull);
    expect(session.status, isNot(SessionStatus.authenticated));
    expect(keyWrites(from), isEmpty);
  });

  test(
      'Stage1 uncleared revoked marker blocks actual bootstrap legacy adoption',
      () async {
    storage.data[RemoveDataFlow.revokedKey] = '["uid-x"]';
    storage.data[kMarkerKey] = 'uid-x';
    final legacy = File(p.join(support.path, 'money_companion.sqlite'))
      ..writeAsBytesSync(List<int>.filled(64, 7));
    storage.gate = (op, key) async {
      if (op == 'read' && key == kMarkerKey) storage.data[kMarkerKey] = 'uid-x';
    };
    final from = storage.attempts.length;
    final runner = await boot();
    storage.gate = null;
    expect(legacy.existsSync(), isTrue);
    expect(replicaDirs(), isEmpty);
    expect(keyWrites(from), isEmpty);
    expect(
        storage.attempts
            .skip(from)
            .where((a) => a.startsWith('write:qirsh.replicas.v1=')),
        isEmpty);
    expect(runner.accountScope.activeUid, isNull);
    expect(session.status, isNot(SessionStatus.authenticated));
    expect(
        queue.calls
            .where((c) => c.startsWith('begin') || c.startsWith('finish')),
        isEmpty);
  });

  test(
      'R2-7 Remove data from an authenticated user through the real startup: '
      'revalidation and auth events during the removal attempt NOTHING for X; '
      'a restart with the stale session stays signed out; a fresh explicit '
      'login creates exactly one replica', () async {
    var runner = await boot(staleSessionOf: 'uid-x');
    debugPrint('IT-STEP before: await signIn(uid-x);');
    await signIn('uid-x');
    expect(session.status, SessionStatus.authenticated);
    expect(replicaDirs(), hasLength(1));
    expect(runner.accountScope.activeUid, 'uid-x');

    // Pause the removal after the scope swap, while the stale session is live.
    final hold = storage.holdOnce(
        (op, key) => op == 'delete' && key.startsWith(kConsentAskedKeyPrefix));
    final from = storage.attempts.length;
    final removal = session.removeDataFromDevice();
    debugPrint('IT-STEP before: await hold.reached.future;');
    await hold.reached.future;
    expect(runner.accountScope.activeUid, isNull,
        reason: 'the signed-out scope is published: the root remounts');
    final client = await F2Fixture.liveClient('uid-x');
    expect(await session.revalidateForShell(client), isFalse);
    await session.revalidateSupabaseSessionOnResume(client);
    await client.auth.refreshSession(); // tokenRefreshed on the bound listener
    await Future<void>.delayed(const Duration(milliseconds: 50));
    debugPrint('IT-STEP before: hold.release.complete();');
    hold.release.complete();
    await removal;
    await session.drainAdmissions();

    expect(admissionWrites(from), isEmpty,
        reason: 'ZERO attempted marker/generation/key/registry writes');
    expect(replicaDirs(), isEmpty);
    expect(
        storage.data.keys.where((k) => k.startsWith('qirsh.db_key.')), isEmpty);
    expect(storage.data.containsKey(kMarkerKey), isFalse);
    expect(session.status, isNot(SessionStatus.authenticated));
    expect(queue.calls, containsAllInOrder(['begin:uid-x', 'finish:uid-x']));

    // Restart with the stale persisted Supabase session of X.
    for (final r in [...runners]) {
      await r.accountScope.lock();
    }
    session.debugResetAdmissionState();
    session.configureRemoveData(null);
    session.configureAccountScope(null);
    final afterRemoval = storage.attempts.length;
    debugPrint('IT-STEP before: runner = await boot(staleSessionOf: uid');
    runner = await boot(staleSessionOf: 'uid-x');
    await session
        .revalidateSupabaseSessionOnResume(await F2Fixture.liveClient('uid-x'));
    await session.drainAdmissions();
    expect(admissionWrites(afterRemoval), isEmpty);
    expect(replicaDirs(), isEmpty);
    expect(runner.accountScope.activeUid, isNull);
    expect(session.status, isNot(SessionStatus.authenticated));

    // A fresh explicit login succeeds exactly once and creates one replica.
    debugPrint('IT-STEP before: final beforeLogin = storage.attempts.len');
    final beforeLogin = storage.attempts.length;
    await signIn('uid-x');
    expect(replicaDirs(), hasLength(1));
    expect(keyWrites(beforeLogin), hasLength(1));
    expect(runner.accountScope.activeUid, 'uid-x');
    expect(storage.data.containsKey(RemoveDataFlow.revokedKey), isFalse,
        reason: 'the explicit admission committed and lifted the revocation');
  });

  for (final (label, read) in [
    ('a native barrier of unknown uid', _present),
    ('a MALFORMED native barrier answer', _malformed),
  ]) {
    test(
        'R2-7 $label blocks the real launch: no legacy adoption, no auth '
        'bind/reconcile, no replica opened, nothing routed authenticated',
        () async {
      var runner = await boot(staleSessionOf: 'uid-y');
      await signIn('uid-y');
      expect(session.status, SessionStatus.authenticated);
      final hashDirs = replicaDirs();
      final yLocation = await runner.accountScope.store.locationFor('uid-y');
      final yKey = storage.data[yLocation.keyName];
      // A legacy database appears, and the native barrier becomes unreadable.
      final legacy = File(p.join(support.path, 'money_companion.sqlite'))
        ..writeAsBytesSync(List<int>.filled(64, 7));
      queue.barrier = read();
      for (final r in [...runners]) {
        await r.accountScope.lock();
      }
      session.debugResetAdmissionState();
      session.configureRemoveData(null);
      session.configureAccountScope(null);
      final from = storage.attempts.length;
      queue.calls.clear();

      runner = await boot(staleSessionOf: 'uid-y');
      await session.revalidateSupabaseSessionOnResume(
          await F2Fixture.liveClient('uid-y'));
      await session.drainAdmissions();

      expect(legacy.existsSync(), isTrue,
          reason: 'the legacy file was neither adopted nor quarantined');
      expect(Directory(p.join(replicas().path, '_quarantine')).existsSync(),
          isFalse);
      expect(runner.accountScope.activeUid, isNull,
          reason: 'only the signed-out scope is opened');
      expect(replicaDirs(), hashDirs, reason: 'no replica created or removed');
      expect(session.status, isNot(SessionStatus.authenticated));
      expect(admissionWrites(from), isEmpty);
      expect(
          queue.calls
              .where((c) => c.startsWith('begin') || c.startsWith('finish')),
          isEmpty,
          reason: 'no uid is guessed from the barrier');
      expect(storage.data[kMarkerKey], 'uid-y',
          reason: 'the marker is left alone, just not opened');

      // Control: once the barrier reads cleanly the same launch proceeds.
      queue.barrier = const CaptureRemovalBarrierRead.absent();
      for (final r in [...runners]) {
        await r.accountScope.lock();
      }
      session.debugResetAdmissionState();
      session.configureRemoveData(null);
      session.configureAccountScope(null);
      // Fixture teardown locked Y. Restore its pre-barrier active state so
      // an owned leftover is not mistaken for a pending legacy adoption.
      await runners.last.accountScope.store
          .setState('uid-y', ReplicaState.active);
      runner = await boot(staleSessionOf: 'uid-y');
      expect(legacy.existsSync(), isTrue,
          reason:
              'active non-adoptPending Y retains unrelated legacy leftover');
      expect(replicaDirs(), hashDirs);
      expect(File(yLocation.dbPath).existsSync(), isTrue);
      expect(storage.data[yLocation.keyName], yKey);
      expect(runner.accountScope.activeUid, 'uid-y');
    });
  }
}

CaptureRemovalBarrierRead _present() => CaptureRemovalBarrierRead.parse(
    {'nonce': 'n', 'uidHash': 'h', 'startedAt': 't'});
CaptureRemovalBarrierRead _malformed() =>
    CaptureRemovalBarrierRead.parse({'nonce': 1});
