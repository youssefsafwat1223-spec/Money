import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_local_notifications_platform_interface/flutter_local_notifications_platform_interface.dart';
import 'package:money_companion/app.dart';
import 'package:money_companion/main.dart';
import 'package:money_companion/core/backend/auth_client_provider.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/router/app_router.dart';
import 'package:money_companion/core/session/remove_data_flow.dart';
import 'package:money_companion/core/session/admission_authority.dart';
import 'package:money_companion/data/db/replica_store.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/replica_location.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/core/session/capture_queue.dart';
import 'package:money_companion/core/startup/bootstrap_runner.dart';
import 'package:money_companion/features/app/app_shell.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';
import '../session/f2_fixture.dart';
import '../session/recording_secure_storage.dart';

class _Notifications extends FlutterLocalNotificationsPlatform {
  @override
  Future<NotificationAppLaunchDetails?>
      getNotificationAppLaunchDetails() async => null;
}

class _Queue implements CaptureQueueBridge {
  CaptureRemovalBarrierRead barrier = const CaptureRemovalBarrierRead.absent();
  @override
  Future<CaptureRemovalBarrierRead> getCaptureRemovalBarrier() async => barrier;
  @override
  Future<void> beginCaptureRemoval(String uid) async {}
  @override
  Future<void> finishCaptureRemoval(String uid) async {}
  @override
  Future<int> captureOwnerEpoch() async => 0;
  @override
  Future<bool> clearCaptureOwner({bool clearHint = false}) async => true;
  @override
  Future<void> publishCaptureOwner(
      {required String uid,
      required bool cloud,
      required bool ai,
      required int version,
      required int expectedEpoch,
      int? transitionGeneration}) async {}
}

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 400 && !ready(); i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(ready(), isTrue);
}

void main() {
  setUp(() => rootBundle.clear());
  tearDown(() => AppSession.instance.debugAuthEventCompleted = null);
  testWidgets(
      'Stage3 real startup mounts the production shell for current explicit admission',
      (tester) async {
    final support = Directory.systemTemp.createTempSync('f2_root_');
    final storage = RecordingSecureStorage().install();
    storage.data['welcome_manifesto_seen'] = '1';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => support.path);
    FlutterLocalNotificationsPlatform.instance = _Notifications();
    final session = AppSession.instance;
    session.debugResetAdmissionState();
    session.configureRemoveData(null);
    session.configureAccountScope(null);
    final client = await tester.runAsync(() => F2Fixture.liveClient('uid-x'));
    final storageEvents = <String>[];
    final runner = BootstrapRunner(
        debugAuthClient: client, debugStorageEvent: storageEvents.add)
      ..captureQueue = _Queue();
    await tester.pumpWidget(StartupApp(
        runner: runner,
        externalOverrides: [authClientProvider.overrideWithValue(client)]));
    await _until(tester, () => find.byType(MoneyApp).evaluate().isNotEmpty);
    final localReached = Completer<void>();
    final localRelease = Completer<void>();
    runner.accountScope.addListener(() {
      final scope = runner.accountScope.current;
      if (scope?.uid == 'uid-x') {
        scope!.database.debugBeforeCustomInsert = (query) async {
          if (query.contains('INSERT INTO remote_currencies') &&
              !localReached.isCompleted) {
            localReached.complete();
            await localRelease.future;
          }
        };
      }
    });
    var signed = false;
    await tester.runAsync(() async {
      unawaited(session
          .completeOnboarding(
              method: 'google', email: 'x@example.com', userId: 'uid-x')
          .then((_) => signed = true));
    });
    await _until(tester, () => signed);
    await _until(tester, () => find.byType(AppShell).evaluate().isNotEmpty);
    await _until(tester, () => localReached.isCompleted);
    expect(runner.accountScope.activeUid, 'uid-x');
    final admitted = runner.accountScope.current!;
    final rootContainer =
        ProviderScope.containerOf(tester.element(find.byType(MoneyApp)));
    expect(rootContainer.read(appDatabaseProvider), same(admitted.database));
    expect(find.byKey(ValueKey(admitted.generation)), findsOneWidget);
    late ReplicaStore artifacts;
    await tester.runAsync(() async {
      artifacts = ReplicaStore(appSupportDirectory: support.path);
      await artifacts.openReplica('uid-y',
          authority: const AdmissionAuthority.forTest('uid-y'));
      await artifacts.closeAll();
    });
    final yLocation =
        await tester.runAsync(() => artifacts.locationFor('uid-y'));
    final yKey = storage.data[yLocation!.keyName];
    final eventCompleted = Completer<void>();
    session.debugAuthEventCompleted = (event) {
      if (event.name == "tokenRefreshed" && !eventCompleted.isCompleted) {
        eventCompleted.complete();
      }
    };
    debugPrint("ROOT before refresh gate");
    final hold = storage.holdOnce(
        (op, key) => op == 'read' && key == RemoveDataFlow.revokedKey);
    await tester.runAsync(() async {
      unawaited(client!.auth.refreshSession());
    });
    await _until(tester, () => hold.reached.isCompleted);
    debugPrint("ROOT gate reached");
    var removed = false;
    await tester.runAsync(() async {
      unawaited(session.removeDataFromDevice().then((_) => removed = true));
    });
    await tester.pump(const Duration(milliseconds: 50));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    expect(removed, isFalse,
        reason: 'removal drains the real open seed transaction');
    expect(admitted.database.lifecycleState.name, 'open');
    localRelease.complete();
    await _until(tester, () => removed);
    await _until(tester, () => find.byType(AppShell).evaluate().isEmpty);
    debugPrint("ROOT removal complete");
    final signedOut = runner.accountScope.current!;
    expect(signedOut.generation, isNot(admitted.generation));
    expect(signedOut.database, isNot(same(admitted.database)));
    expect(
        ProviderScope.containerOf(tester.element(find.byType(MoneyApp)))
            .read(appDatabaseProvider),
        same(signedOut.database));
    expect(
        appRouter.routeInformationProvider.value.uri.path, '/onboarding/auth');
    final from = storage.attempts.length;
    final openerFrom = storageEvents.length;
    hold.release.complete();
    var drained = false;
    await tester.runAsync(() async {
      unawaited(session.drainAdmissions().then((_) => drained = true));
    });
    await _until(tester, () => drained && eventCompleted.isCompleted);
    session.debugAuthEventCompleted = null;
    debugPrint("ROOT old callback drained");
    await tester.pump(const Duration(milliseconds: 100));
    final forbidden = storage.attempts.skip(from).where((a) =>
        a.startsWith('write:qirsh.db_key.') ||
        a.startsWith('write:qirsh.replicas.v1=') ||
        a.startsWith('write:$kMarkerKey=') ||
        a.startsWith('write:$kGenerationKey='));
    expect(forbidden, isEmpty);
    expect(storageEvents.skip(openerFrom), isEmpty);
    expect(File(yLocation.dbPath).existsSync(), isTrue);
    expect(storage.data[yLocation.keyName], yKey);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    var locked = false;
    await tester.runAsync(() async {
      unawaited(runner.accountScope.lock().then((_) => locked = true));
    });
    await _until(tester, () => locked);
    runner.accountScope.dispose();
    session.debugResetAdmissionState();
    session.configureRemoveData(null);
    session.configureAccountScope(null);
    final restartFrom = storage.attempts.length;
    final restartedEvents = <String>[];
    final restarted = BootstrapRunner(
        debugAuthClient: client, debugStorageEvent: restartedEvents.add)
      ..captureQueue = _Queue();
    await tester.pumpWidget(StartupApp(
        runner: restarted,
        externalOverrides: [authClientProvider.overrideWithValue(client)]));
    await _until(tester, () => find.byType(MoneyApp).evaluate().isNotEmpty);
    expect(find.byType(AppShell), findsNothing);
    expect(
        storage.attempts
            .skip(restartFrom)
            .where((a) => a.startsWith('write:qirsh.db_key.')),
        isEmpty);
    expect(restartedEvents, isEmpty);
    final freshFrom = storage.attempts.length;
    var fresh = false;
    await tester.runAsync(() async {
      unawaited(session
          .completeOnboarding(
              method: 'google', email: 'x@example.com', userId: 'uid-x')
          .then((_) => fresh = true));
    });
    await _until(tester, () => fresh);
    await _until(tester, () => find.byType(AppShell).evaluate().isNotEmpty);
    expect(
        storage.attempts
            .skip(freshFrom)
            .where((a) => a.startsWith('write:qirsh.db_key.')),
        hasLength(1));
    expect(restartedEvents.where((e) => e == "native-open"), hasLength(1));
    expect(
        ProviderScope.containerOf(tester.element(find.byType(MoneyApp)))
            .read(appDatabaseProvider),
        same(restarted.accountScope.current!.database));
    expect(storage.data[yLocation.keyName], yKey);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    var closed = false;
    await tester.runAsync(() async {
      unawaited(restarted.accountScope.lock().then((_) => closed = true));
    });
    await _until(tester, () => closed);
    restarted.accountScope.dispose();
    session.configureRemoveData(null);
    session.configureAccountScope(null);
    await tester.pump(const Duration(seconds: 2));
    await tester.runAsync(() async => support.deleteSync(recursive: true));
  });
  testWidgets(
      'Stage3 real startup legitimately adopts owned legacy data without removal',
      (tester) async {
    final support = Directory.systemTemp.createTempSync('f2_root_legacy_');
    final storage = RecordingSecureStorage().install();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => support.path);
    FlutterLocalNotificationsPlatform.instance = _Notifications();
    final session = AppSession.instance;
    session.debugResetAdmissionState();
    session.configureRemoveData(null);
    session.configureAccountScope(null);
    await tester.runAsync(() async {
      final legacy =
          await AppDatabase.open(location: await ReplicaLocation.legacy());
      await legacy.customStatement(
          "INSERT INTO transactions(id, amount, amount_minor, currency, type, source, occurred_at, raw_message, parse_confidence, status, created_at, updated_at, sync_status, direction) VALUES ('legacy-control', 10, 1000, 'SAR', 'payment', 'manual', '2026-10-01T00:00:00Z', '', 1, 'confirmed', '2026-10-01T00:00:00Z', '2026-10-01T00:00:00Z', 'synced', 'debit');");
      await legacy.close();
    });
    storage.data[kMarkerKey] = 'uid-x';
    storage.data['welcome_manifesto_seen'] = '1';
    final client = await tester.runAsync(() => F2Fixture.liveClient('uid-x'));
    final runner = BootstrapRunner(debugAuthClient: client)
      ..captureQueue = _Queue();
    await tester.runAsync(() async {
      await tester.pumpWidget(StartupApp(
          runner: runner,
          externalOverrides: [authClientProvider.overrideWithValue(client)]));
    });
    await _until(tester, () => find.byType(MoneyApp).evaluate().isNotEmpty);
    final entries =
        await tester.runAsync(() => runner.accountScope.store.list());
    expect(entries, hasLength(1));
    expect(entries!.single.legacyAdoptedAt, isNotNull);
    final loc = await tester
        .runAsync(() => runner.accountScope.store.locationFor('uid-x'));
    expect(File(loc!.dbPath).existsSync(), isTrue);
    final count = await tester.runAsync(() async {
      final db = await runner.accountScope.store.openReplica('uid-x');
      return (await db
              .customSelect(
                  "SELECT COUNT(*) AS n FROM transactions WHERE id = 'legacy-control';")
              .getSingle())
          .read<int>('n');
    });
    expect(count, 1);
    expect(
        File('${support.path}/money_companion.sqlite').existsSync(), isFalse);
    expect(File('${support.path}/money_companion.sqlite.adopted').existsSync(),
        isTrue,
        reason: 'verified adoption retains its rollback source');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    var locked = false;
    await tester.runAsync(() async {
      unawaited(runner.accountScope.lock().then((_) => locked = true));
    });
    await _until(tester, () => locked);
    runner.accountScope.dispose();
    session.configureRemoveData(null);
    session.configureAccountScope(null);
    await tester.pump(const Duration(seconds: 2));
    support.deleteSync(recursive: true);
  });

  for (final failure in [
    'durable-malformed',
    'durable-read-error',
    'native-malformed',
    'revoked-marker-delete-failure'
  ]) {
    testWidgets('Stage3 actual cold root blocks $failure with retained legacy',
        (tester) async {
      final support = Directory.systemTemp.createTempSync('f2_root_blocked_');
      final storage = RecordingSecureStorage().install();
      storage.data['welcome_manifesto_seen'] = '1';
      final legacy = File('${support.path}/money_companion.sqlite')
        ..writeAsBytesSync(List.filled(64, 7));
      if (failure == 'durable-malformed') {
        storage.data[RemoveDataFlow.barrierKey] = '{invalid';
      }
      if (failure == 'revoked-marker-delete-failure') {
        storage.data[RemoveDataFlow.revokedKey] = '["uid-x"]';
        storage.data[kMarkerKey] = 'uid-x';
      }
      storage.gate = (op, key) async {
        if (failure == 'durable-read-error' &&
            op == 'read' &&
            key == RemoveDataFlow.barrierKey) {
          throw StateError('fixture read unavailable');
        }
        if (failure == 'revoked-marker-delete-failure' &&
            op == 'read' &&
            key == kMarkerKey) {
          storage.data[kMarkerKey] = 'uid-x';
        }
      };
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              (call) async => support.path);
      FlutterLocalNotificationsPlatform.instance = _Notifications();
      final session = AppSession.instance;
      session.debugResetAdmissionState();
      session.configureRemoveData(null);
      session.configureAccountScope(null);
      final client = await tester.runAsync(() => F2Fixture.liveClient('uid-x'));
      final queue = _Queue();
      if (failure == 'native-malformed') {
        queue.barrier = const CaptureRemovalBarrierRead.malformed();
      }
      final events = <String>[];
      final runner = BootstrapRunner(
          debugAuthClient: client, debugStorageEvent: events.add)
        ..captureQueue = queue;
      final from = storage.attempts.length;
      await tester.pumpWidget(StartupApp(
          runner: runner,
          externalOverrides: [authClientProvider.overrideWithValue(client)]));
      await _until(
          tester,
          () => failure == 'durable-read-error'
              ? find.text('Qirsh could not start').evaluate().isNotEmpty
              : find.byType(MoneyApp).evaluate().isNotEmpty);
      expect(find.byType(AppShell), findsNothing);
      expect(events, isEmpty);
      expect(runner.accountScope.activeUid, isNull);
      expect(
          storage.attempts.skip(from).where((a) =>
              a.startsWith('write:qirsh.db_key.') ||
              a.startsWith('write:qirsh.replicas.v1=') ||
              (a.startsWith('write:$kMarkerKey=') &&
                  a != 'write:$kMarkerKey=')),
          isEmpty);
      expect(legacy.existsSync(), isTrue);
      expect(Directory('${support.path}/replicas').existsSync(), isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      var locked = false;
      await tester.runAsync(() async {
        unawaited(runner.accountScope.lock().then((_) => locked = true));
      });
      await _until(tester, () => locked);
      runner.accountScope.dispose();
      session.configureRemoveData(null);
      session.configureAccountScope(null);
      await tester.pump(const Duration(seconds: 2));
      support.deleteSync(recursive: true);
    });
  }
}
