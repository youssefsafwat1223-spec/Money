import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_local_notifications_platform_interface/flutter_local_notifications_platform_interface.dart';
import 'package:money_companion/core/startup/bootstrap_runner.dart';
import 'package:money_companion/core/di/rebootstrap_providers.dart';
import 'package:money_companion/core/session/capture_queue.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';
import 'package:money_companion/core/session/account_fence_store.dart';
import 'package:money_companion/core/session/account_fence_authority.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/creation_policy.dart';
import 'package:money_companion/data/db/replica_location.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/capture/services/ledger_outbox_queue.dart';

import '../session/f2_fixture.dart';

const _uid = 'uid-stage-b';
const _transactionId = 'authority-stage-b-transaction';
const _operationId = '550e8400-e29b-41d4-a716-446655440000';

class _Snapshot {
  _Snapshot(this.transaction, this.queue);
  final Map<String, Object?> transaction;
  final List<Map<String, Object?>> queue;
}

Future<_Snapshot> _snapshot(AppDatabase database) async => _Snapshot(
    (await database.customSelect(
        "SELECT * FROM transactions WHERE id = '$_transactionId';").getSingle()).data,
    [for (final row in await database.customSelect(
        'SELECT * FROM ledger_sync_outbox ORDER BY id;').get()) row.data]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late F2Fixture fixture;
  late void Function() restorePersistence;
  late ReplicaLocation location;
  late AppDatabase originalDatabase;
  late _Snapshot original;
  late String ownerGeneration;
  late int scopeGeneration;
  late String keyValue;
  late Set<String> closedArtifacts;

  setUp(() async {
    restorePersistence = AccountFenceAuthority.replacePersistenceForTest();
    fixture = await F2Fixture.create(afterWithdraw: () async {});
    await fixture.signIn(_uid);
    expect(fixture.session.status, SessionStatus.authenticated);
    final scope = fixture.host.current!;
    expect(scope.uid, _uid);
    expect(scope.location, isNotNull);
    location = scope.location!;
    originalDatabase = scope.database;
    scopeGeneration = scope.generation;
    ownerGeneration = fixture.storage.data[kGenerationKey]!;
    expect(ownerGeneration, isNotEmpty);
    keyValue = fixture.storage.data[location.keyName]!;
    expect(keyValue, isNotEmpty);
    final queue = LedgerOutboxQueue(db: originalDatabase,
        isPushEnabled: () => true, getAuthUserId: () async => _uid,
        getOwnerUid: fixture.session.readLocalDataOwnerUid);
    final now = DateTime.utc(2026, 10, 1);
    await DriftTransactionRepository(originalDatabase, outboxQueue: queue)
        .saveTransaction(transaction: TransactionEntity(
          id: _transactionId, amountMoney: Money(2500, 'EGP'), currency: 'EGP',
          type: TransactionTypeEntity.payment, source: TransactionSourceEntity.bank,
          direction: TransactionDirectionEntity.debit,
          occurredAt: now, rawMessage: '', parseConfidence: 1,
          status: TransactionStatus.confirmed, createdAt: now, updatedAt: now,
        ), categoryKey: null);
    original = await _snapshot(originalDatabase);
    expect(original.queue, hasLength(1));
    expect(original.queue.single['attempt_count'], 0);
    expect(original.queue.single['operation_id'], isNotNull);
    expect(original.queue.single['in_flight_seq'], isNull,
        reason: 'inspection never hands the queued operation to a worker');
  });

  tearDown(() async {
    await fixture.dispose();
    restorePersistence();
  });

  Set<String> artifacts() => Directory(location.directory).listSync()
      .map((entry) => entry.path).toSet();

  Future<String?> persist(AccountFenceState? state) async {
    final store = AccountFenceStore();
    final owner = AccountFenceStore.ownerDigest(_uid);
    if (state != null) {
      expect(await store.record(owner, AccountFenceRecord(
          state: state, operationId: _operationId,
          ownerGeneration: ownerGeneration,
          replicaDigest: AccountFenceStore.replicaDigest(location.dbPath, location.keyName),
          scopeGeneration: scopeGeneration)), isTrue);
    } else {
      expect(await store.load(), isTrue);
      expect(store.allows(owner), isTrue);
    }
    final encoded = fixture.storage.data[AccountFenceStore.storageKey];
    if (state == null) {
      expect(encoded, isNull);
    } else {
      expect(encoded, isNotNull);
    }
    final rebuilt = AccountFenceStore();
    expect(await rebuilt.load(), isTrue);
    expect(rebuilt.holdFor(owner)?.state, state);
    expect(rebuilt.allows(owner), state == null);
    return encoded;
  }

  Future<void> restart(String? encoded) async {
    await fixture.restart();
    expect(originalDatabase.lifecycleState, DatabaseLifecycleState.closed,
        reason: 'privileged inspection is forbidden until the host connection closed');
    expect(File(location.dbPath).existsSync(), isTrue);
    expect(fixture.storage.data[location.keyName] == keyValue, isTrue,
        reason: 'the existing replica key must survive reconstruction');
    expect(fixture.storage.data[AccountFenceStore.storageKey] == encoded, isTrue);
    expect(fixture.storage.data[kMarkerKey], _uid);
    closedArtifacts = artifacts();
  }

  Future<void> preserves(String? encoded) async {
    expect(fixture.storage.data[AccountFenceStore.storageKey] == encoded, isTrue,
        reason: 'admission cannot clear or rewrite the durable denial');
    expect(fixture.storage.data[kMarkerKey], _uid);
    expect(fixture.storage.data[kGenerationKey] == ownerGeneration, isTrue);
    expect(fixture.storage.data[location.keyName] == keyValue, isTrue);
    expect(File(location.dbPath).existsSync(), isTrue);
    expect(fixture.order, isEmpty, reason: 'denial never invokes Remove data barriers');
    // A failing pre-integration explicit admission can actually reopen the owner.
    // Observe it first, then close the real host connection before storage-only
    // inspection. This lock is test cleanup, never the denial implementation.
    final active = fixture.host.current;
    if (active?.uid == _uid) {
      final database = active!.database;
      await fixture.host.lock();
      expect(database.lifecycleState, DatabaseLifecycleState.closed);
    }
    expect(originalDatabase.lifecycleState, DatabaseLifecycleState.closed);
    expect(artifacts(), closedArtifacts,
        reason: 'the attempted admission must not create a new replica artifact');
    // Privileged temporary-fixture inspection only: no publication/attachment,
    // no migrations and no permission to create a missing file or key.
    final inspection = await AppDatabase.open(location: location,
        runMigrations: false, creation: const CreationPolicy.denied());
    try {
      final after = await _snapshot(inspection);
      expect(after.transaction, original.transaction);
      expect(after.queue, original.queue,
          reason: 'no ACK, payload/replay rewrite, failure or business attempt');
    } finally {
      await inspection.close();
    }
    expect(artifacts(), closedArtifacts,
        reason: 'the storage-only inspection leaves no new persistent artifact');
    expect(fixture.storage.data[location.keyName] == keyValue, isTrue);
  }

  test('E4 authority Stage B clear launch marker remains eligible', () async {
    final encoded = await persist(null);
    await restart(encoded);
    final launch = await fixture.session.prepareLaunchAdmission();
    await preserves(encoded);
    expect(launch.blocked, isFalse);
    expect(launch.uid, _uid);
  });

  test('E4 authority Stage B clear explicit reauthentication reopens preserved replica', () async {
    final encoded = await persist(null);
    await restart(encoded);
    await fixture.signIn(_uid);
    expect(fixture.session.status, SessionStatus.authenticated);
    expect(fixture.host.current?.uid, _uid);
    await preserves(encoded);
  });

  for (final state in AccountFenceState.values) {
    test('E4 authority Stage B ${state.name} blocks real launch admission without erasing local intent', () async {
      final encoded = await persist(state);
      await restart(encoded);
      final launch = await fixture.session.prepareLaunchAdmission();
      final status = fixture.session.status;
      await preserves(encoded);
      expect(launch.blocked, isTrue);
      expect(launch.uid, isNull);
      expect(status, isNot(SessionStatus.authenticated));
    });

    test('E4 authority Stage B ${state.name} blocks explicit completeOnboarding without erasing local intent', () async {
      final encoded = await persist(state);
      await restart(encoded);
      Object? rejection;
      try {
        await fixture.signIn(_uid);
      } catch (error) {
        rejection = error;
      }
      final publishedOwner = fixture.host.current?.uid;
      final status = fixture.session.status;
      await preserves(encoded);
      expect(rejection, isNotNull, reason: 'the existing real explicit admission must refuse the persisted hold');
      expect(publishedOwner, isNot(_uid));
      expect(status, isNot(SessionStatus.authenticated));
    });
  }
  for (final mode in ['clear', 'pending', 'gone', 'malformed', 'unreadable', 'version']) {
    test('E4 authority reconstructed bootstrap valid SDK session hold=$mode never opens held owner', () async {
      final state = mode == 'pending' ? AccountFenceState.pending
          : mode == 'gone' ? AccountFenceState.gone : null;
      await persist(state);
      if (mode == 'malformed') fixture.storage.data[AccountFenceStore.storageKey] = '{broken';
      if (mode == 'version') fixture.storage.data[AccountFenceStore.storageKey] = '{"version":2,"owners":{}}';
      final encoded = fixture.storage.data[AccountFenceStore.storageKey];
      // A process shutdown closes without sign-out: preserve the ACTIVE registry
      // so the clean control can prove an existing replica really opens.
      await fixture.host.detach();
      expect(originalDatabase.lifecycleState, DatabaseLifecycleState.closed);
      await fixture.host.current?.database.close();
      fixture.session.configureAccountScope(null);
      fixture.session.configureRemoveData(null);
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => fixture.support.path);
      FlutterLocalNotificationsPlatform.instance = _NoNotifications();
      final client = await F2Fixture.liveClient(_uid);
      if (mode == 'unreadable') {
        fixture.storage.gate = (op, key) async {
          if (op == 'read' && key == AccountFenceStore.storageKey) throw StateError('storage unavailable');
        };
      }
      final events = <String>[];
      final runner = BootstrapRunner(debugAuthClient: client,
          debugStorageEvent: events.add, debugAfterWithdraw: () async {})
        ..captureQueue = _CaptureQueue();
      try {
        await runner.run();
        expect(fixture.storage.data[AccountFenceStore.storageKey] == encoded, isTrue);
        expect(fixture.storage.data[location.keyName] == keyValue, isTrue);
        if (mode == 'clear') {
          expect(runner.accountScope.current?.uid, _uid);
          expect(events, contains('native-open'));
          expect(fixture.session.status, SessionStatus.authenticated);
        } else {
          expect(runner.accountScope.current?.uid, isNull);
          expect(events, isEmpty, reason: 'no owner opener/adoption/liveness/native-open before denial');
          expect(fixture.session.status, isNot(SessionStatus.authenticated));
          final runtime = RebootstrapRuntime.instance;
          await expectLater(runtime.maintenanceAuthority!(_uid),
              throwsA(isA<AccountFenceDeniedException>()));
          await runtime.readmit!(_uid, null);
          expect(runner.accountScope.current?.uid, isNull);
          expect(fixture.storage.data[AccountFenceStore.storageKey] == encoded, isTrue);
          expect(events, isEmpty);
        }
      } finally {
        fixture.storage.gate = null;
        await runner.accountScope.lock();
        runner.accountScope.dispose();
        fixture.session.configureAccountScope(null);
        fixture.session.configureRemoveData(null);
        await client.dispose();
        messenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), null);
      }
    });
  }

}


class _NoNotifications extends FlutterLocalNotificationsPlatform {
  @override
  Future<NotificationAppLaunchDetails?> getNotificationAppLaunchDetails() async => null;
}

class _CaptureQueue implements CaptureQueueBridge {
  @override
  Future<CaptureRemovalBarrierRead> getCaptureRemovalBarrier() async => const CaptureRemovalBarrierRead.absent();
  @override
  Future<void> beginCaptureRemoval(String uid) async => throw StateError('unexpected removal');
  @override
  Future<void> finishCaptureRemoval(String uid) async => throw StateError('unexpected removal');
  @override
  Future<int> captureOwnerEpoch() async => 0;
  @override
  Future<bool> clearCaptureOwner({bool clearHint = false}) async => true;
  @override
  Future<void> publishCaptureOwner({required String uid, required bool cloud,
    required bool ai, required int version, required int expectedEpoch,
    int? transitionGeneration}) async {}
}
