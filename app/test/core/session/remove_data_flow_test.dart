import 'dart:async';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/session/account_scope.dart';
import 'package:money_companion/core/session/admission_authority.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/core/session/capture_queue.dart';
import 'package:money_companion/core/session/remove_data_flow.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart'
    show CaptureRemovalBarrier, CaptureRemovalBarrierRead;
import 'package:money_companion/data/db/replica_store.dart';
import 'package:path/path.dart' as p;

import 'fake_remove_barrier.dart';
import 'recording_secure_storage.dart';

// WP-3b — the §4.4 Remove-data barrier, Dart side, over real replicas and a
// fake native queue (the CAP-6a bridge methods are expected at the seam).

class _Crash implements Exception {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory support;
  late List<String> order;
  late FakeRemoveBarrier barrier;
  late ReplicaStore store;
  late AccountScopeHost host;
  late RecordingSecureStorage rec;

  RemoveDataFlow flow({String? crashAfter, bool withCleanup = true}) =>
      RemoveDataFlow(
        store: store,
        scope: _Recording(host, order),
        barrier: barrier,
        clearOwnerMarker: (_) async {
          order.add('clearMarker');
        },
        serverCleanupBestEffort:
            withCleanup ? () async => order.add('serverCleanup') : null,
        debugAfterStep: crashAfter == null
            ? null
            : (s) async {
                if (s == crashAfter) throw _Crash();
              },
      );

  Directory replicaDir(String hash) =>
      Directory(p.join(support.path, 'replicas', hash));

  setUp(() async {
    support = Directory.systemTemp.createTempSync('remove_flow_');
    rec = RecordingSecureStorage().install();
    order = [];
    barrier = FakeRemoveBarrier(order);
    store = ReplicaStore(requireCreationAuthority: false, appSupportDirectory: support.path);
    host = AccountScopeHost(
      store: store,
      initialize: (db, uid) async => const AccountScopeInit(),
    );
    await host.activate('uid-a');
    await host.activate('uid-b'); // A is locked, B active
  });

  tearDown(() async {
    await host.lock();
    host.dispose();
    support.deleteSync(recursive: true);
  });

  test('steps run in the manifest order and delete ONLY that uid\'s replica',
      () async {
    final hashA = await store.uidHash('uid-a');
    final hashB = await store.uidHash('uid-b');

    await flow().remove('uid-b');

    expect(order, [
      'begin:uid-b', // 1 native barrier (flock)
      'clearMarker', // 1 owner record cleared
      'detach', //      2 scope stopped, replica closed
      'serverCleanup', // 4 best effort
      'finish:uid-b', // 5 final sweep + clear barrier
    ]);
    expect(replicaDir(hashB).existsSync(), isFalse);
    expect(replicaDir(hashA).existsSync(), isTrue, reason: 'other replicas intact');
    expect(await storage_(const FlutterSecureStorage(), 'qirsh.db_key.$hashB'), isNull);
    expect(await storage_(const FlutterSecureStorage(), 'qirsh.db_key.$hashA'),
        isNotNull);
    expect(await flow().hasPending(), isFalse);
    expect(host.current!.uid, isNull, reason: 'signed-out scope after removal');
  });

  test('a failed final sweep keeps the barrier and reports incomplete',
      () async {
    barrier.failFinish = true;
    await expectLater(flow().remove('uid-b'),
        throwsA(isA<RemoveDataIncompleteException>()));
    expect(await flow().hasPending(), isTrue);
  });

  for (final step in kRemovalSteps) {
    test('crash after "$step": the next launch resumes and completes',
        () async {
      final hashB = await store.uidHash('uid-b');
      await expectLater(flow(crashAfter: step).remove('uid-b'),
          throwsA(isA<RemoveDataIncompleteException>()));
      expect(await flow().hasPending(), isTrue,
          reason: 'barrier persists across the crash');

      // New process: nothing open, then resume at launch.
      order.clear();
      final relaunch = flow();
      expect(await relaunch.resumePending(), isTrue);

      expect(replicaDir(hashB).existsSync(), isFalse);
      expect(await relaunch.hasPending(), isFalse);
      expect(order, contains('finish:uid-b'));
      expect(replicaDir(await store.uidHash('uid-a')).existsSync(), isTrue);
    });
  }

  test('a native barrier with no Dart record (crash between the two writes) '
      'is resumed from the native side', () async {
    barrier.pending = 'uid-b';
    expect(await flow().resumePending(), isTrue);
    expect(order, contains('finish:uid-b'));
    expect(replicaDir(await store.uidHash('uid-b')).existsSync(), isFalse);
  });

  test('resume that cannot complete reports false (admission must wait)',
      () async {
    await expectLater(flow(crashAfter: 'afterBarrierRecord').remove('uid-b'),
        throwsA(anything));
    barrier.failFinish = true;
    expect(await flow().resumePending(), isFalse);
  });

  test('AppSession admits nobody while a removal is pending and unfinishable',
      () async {
    FlutterSecureStorage.setMockInitialValues({});
    await expectLater(flow(crashAfter: 'afterBarrierRecord').remove('uid-b'),
        throwsA(anything));
    barrier.failFinish = true;
    final session = AppSession.instance;
    session.configureRemoveData(flow());
    session.configureCaptureOwnerClear(() async => true);
    try {
      await expectLater(
        session.setIdentity(method: 'google', userId: 'uid-c'),
        throwsA(isA<LocalDataOwnershipException>()),
      );
    } finally {
      session.configureRemoveData(null);
      session.configureCaptureOwnerClear(null);
    }
  });

  test('removeDataFromDevice failure leaves the device signed out locally',
      () async {
    final session = AppSession.instance;
    final scope = _Recording(host, order);
    session.configureAccountScope(scope);
    session.configureCaptureOwnerClear(() async => true);
    session.configureRemoveData(flow());
    barrier.failFinish = true;
    try {
      await session.setIdentity(method: 'google', userId: 'uid-b');
      order.clear();
      await expectLater(session.removeDataFromDevice(),
          throwsA(isA<RemoveDataIncompleteException>()));
      expect(session.status, SessionStatus.needsOnboarding);
      expect(order, contains('lock'));
    } finally {
      session.configureRemoveData(null);
      session.configureAccountScope(null);
      session.configureCaptureOwnerClear(null);
    }
  });

  test('D2: a completed removal sets the one-shot notice and forgets the '
      'consent-asked marker; an incomplete one does not set it', () async {
    final session = AppSession.instance;
    session.configureAccountScope(_Recording(host, order));
    session.configureCaptureOwnerClear(() async => true);
    session.configureRemoveData(flow());
    session.removalNoticePending.value = false;
    try {
      await session.setIdentity(method: 'google', userId: 'uid-b');
      await session.markConsentPromptSeen();
      expect(await session.consentPromptSeen(), isTrue);
      expect(
          await storage_(const FlutterSecureStorage(),
              '${kConsentAskedKeyPrefix}uid-b'),
          isNotNull);

      barrier.failFinish = true;
      await expectLater(session.removeDataFromDevice(),
          throwsA(isA<RemoveDataIncompleteException>()));
      expect(session.removalNoticePending.value, isFalse,
          reason: 'never claim completion for an unfinished removal');

      barrier.failFinish = false;
      await session.setIdentity(method: 'google', userId: 'uid-b');
      await session.removeDataFromDevice();
      expect(session.removalNoticePending.value, isTrue);
      expect(
          await storage_(const FlutterSecureStorage(),
              '${kConsentAskedKeyPrefix}uid-b'),
          isNull,
          reason: 'a fresh replica must re-ask');
    } finally {
      session.removalNoticePending.value = false;
      session.configureRemoveData(null);
      session.configureAccountScope(null);
      session.configureCaptureOwnerClear(null);
    }
  });

  // ---------------------------------------------------------------- F2 ------

  group('F2: durable states, single execution, process death', () {
    test('completion records removed_requires_explicit_auth BEFORE the active '
        'record is cleared; a completed removal is never swept again', () async {
      final f = flow();
      await f.remove('uid-b');
      final revokedAt = rec.attempts
          .indexOf('write:${RemoveDataFlow.revokedKey}=["uid-b"]');
      final barrierClearedAt =
          rec.attempts.indexOf('delete:${RemoveDataFlow.barrierKey}');
      expect(revokedAt, greaterThan(-1));
      expect(barrierClearedAt, greaterThan(revokedAt),
          reason: 'no instant at which neither state exists');
      expect(await f.revokedUids(), {'uid-b'});

      order.clear();
      expect(await f.resumePending(), isTrue);
      expect(order, isEmpty, reason: 'no re-sweep once completed');
    });

    test('a purge removal (revokeAdmission:false) does not revoke the uid',
        () async {
      await flow().remove('uid-b', revokeAdmission: false);
      expect(await flow().revokedUids(), isEmpty);
    });

    test('concurrent remove() and resumePending() share one execution; a second '
        'target waits and never overwrites the first record', () async {
      final gate = Completer<void>();
      final reached = Completer<void>();
      barrier.onCall = (c) async {
        if (c == 'begin:uid-b' && !reached.isCompleted) {
          reached.complete();
          await gate.future;
        }
      };
      final first = flow();
      final running = first.remove('uid-b');
      await reached.future;
      final joined = first.remove('uid-b');
      final resume = first.resumePending();
      final other = first.remove('uid-a'); // another target: queued, not merged
      gate.complete();
      await running;
      await joined;
      expect(await resume, isTrue);
      await other;
      expect(order.where((c) => c == 'begin:uid-b'), hasLength(1));
      expect(order.indexOf('finish:uid-b'), lessThan(order.indexOf('begin:uid-a')),
          reason: 'one sweep at a time');
      expect(await first.revokedUids(), {'uid-a', 'uid-b'});
    });

    test('an unreadable Dart record blocks admission (uid unknown)', () async {
      await const FlutterSecureStorage()
          .write(key: RemoveDataFlow.barrierKey, value: '{not json');
      final f = flow();
      expect(await f.hasPending(), isTrue);
      expect(await f.resumePending(), isFalse);
      expect(order, isEmpty);
    });

    test('a native barrier whose uid is unknown blocks admission and no uid '
        'is invented', () async {
      barrier.unknownBarrier = true;
      final f = flow();
      expect(await f.resumePending(), isFalse);
      expect(order, isEmpty, reason: 'no begin/finish for a guessed uid');
      expect(barrier.unknownBarrier, isTrue, reason: 'left in place');
    });

    test('an unreadable revoked-uid list is an error, not "no restrictions"',
        () async {
      await const FlutterSecureStorage()
          .write(key: RemoveDataFlow.revokedKey, value: 'oops');
      await expectLater(flow().revokedUids(), throwsA(anything));
    });

    test('quiesce runs before anything destructive', () async {
      final f = RemoveDataFlow(
          store: store,
          scope: _Recording(host, order),
          barrier: barrier,
          clearOwnerMarker: (_) async => order.add('clearMarker'),
          quiesce: () async => order.add('quiesce'));
      await f.remove('uid-b');
      expect(order.first, 'quiesce');
    });

    // Process death: every step, with a brand-new store, host, flow and barrier
    // reader (nothing in memory of the dead process survives).
    for (final step in kRemovalSteps) {
      test('process death after "$step": NEW instances finish the removal '
          'before anyone is admitted; revocation is recorded', () async {
        final hashB = await store.uidHash('uid-b');
        await expectLater(flow(crashAfter: step).remove('uid-b'),
            throwsA(isA<RemoveDataIncompleteException>()));
        await host.lock();
        host.dispose();

        final store2 = ReplicaStore(appSupportDirectory: support.path);
        final host2 = AccountScopeHost(
            store: store2,
            initialize: (db, uid) async => const AccountScopeInit());
        final relaunch = RemoveDataFlow(
            store: store2,
            scope: host2,
            barrier: barrier,
            clearOwnerMarker: (_) async {});
        expect(await relaunch.resumePending(), isTrue);
        expect(replicaDir(hashB).existsSync(), isFalse);
        expect(await relaunch.hasPending(), isFalse);
        expect(await relaunch.revokedUids(), {'uid-b'});
        expect(await store2.list().then((l) => l.map((e) => e.uidHash)),
            isNot(contains(hashB)));
        // Host teardown for tearDown().
        host = host2;
      });
    }

    // Crashes INSIDE the replica removal: a storage operation fails mid-way.
    for (final failing in ['key', 'registry', 'consent']) {
      test('storage failure while deleting the $failing: barrier kept, NEW '
          'instances finish it', () async {
        final hashB = await store.uidHash('uid-b');
        var armed = true;
        rec.gate = (op, key) async {
          if (!armed) return;
          final hit = switch (failing) {
            'key' => op == 'delete' && key == 'qirsh.db_key.$hashB',
            'registry' => op == 'write' &&
                key == ReplicaStore.registryKey &&
                rec.deletes.contains('qirsh.db_key.$hashB'),
            _ => op == 'delete' && key == '${kConsentAskedKeyPrefix}uid-b',
          };
          if (hit) {
            armed = false;
            throw StateError('injected');
          }
        };
        await expectLater(flow().remove('uid-b'),
            throwsA(isA<RemoveDataIncompleteException>()));
        expect(await flow().hasPending(), isTrue);
        expect(await flow().revokedUids(), isEmpty,
            reason: 'not yet complete, so not yet `removed`');
        await host.lock();
        host.dispose();

        final store2 = ReplicaStore(appSupportDirectory: support.path);
        final host2 = AccountScopeHost(
            store: store2,
            initialize: (db, uid) async => const AccountScopeInit());
        final again = RemoveDataFlow(
            store: store2,
            scope: host2,
            barrier: barrier,
            clearOwnerMarker: (_) async {});
        expect(await again.resumePending(), isTrue);
        expect(replicaDir(hashB).existsSync(), isFalse);
        expect(rec.data.containsKey('qirsh.db_key.$hashB'), isFalse);
        expect(await again.revokedUids(), {'uid-b'});
        host = host2;
      });
    }
  });

  group('R2-2: the whole removal transaction is serialized', () {
    Future<void> settle() =>
        Future<void>.delayed(const Duration(milliseconds: 200));

    /// The operations on the durable removal record, as `write:<uid>` / `delete`.
    List<String> recordOps() => [
          for (final a in rec.attempts)
            if (a.startsWith('write:${RemoveDataFlow.barrierKey}='))
              'write:${RegExp(r'"uid":"([^"]+)"').firstMatch(a)!.group(1)}'
            else if (a == 'delete:${RemoveDataFlow.barrierKey}')
              'delete',
        ];

    test('R2-2 callers racing BEFORE the first record write never replace each '
        'other\'s durable record', () async {
      final f = flow();
      final a = f.remove('uid-a');
      final b = f.remove('uid-b');
      await a;
      await b;
      expect(recordOps(), ['write:uid-a', 'delete', 'write:uid-b', 'delete'],
          reason: 'the second record is written only after the first was '
              'cleared, never over it');
      expect(await f.revokedUids(), {'uid-a', 'uid-b'});
    });

    test('R2-2 an explicit removal joining a revoke:false purge upgrades the '
        'DURABLE record at once', () async {
      final gate = Completer<void>();
      final reached = Completer<void>();
      barrier.onCall = (c) async {
        if (c == 'begin:uid-b' && !reached.isCompleted) {
          reached.complete();
          await gate.future;
        }
      };
      final f = flow();
      final purge = f.remove('uid-b', revokeAdmission: false);
      await reached.future;
      final explicit = f.remove('uid-b'); // overlaps the purge
      await settle();

      final raw =
          await const FlutterSecureStorage().read(key: RemoveDataFlow.barrierKey);
      expect(raw, contains('"revoke":true'),
          reason: 'a crash now must still resume as an explicit removal');

      gate.complete();
      await purge;
      await explicit;
      expect(await f.revokedUids(), {'uid-b'});
    });

    test('R2-2 a crash after the explicit removal joined a purge is resumed '
        'as an explicit removal (removed_requires_explicit_auth)', () async {
      final gate = Completer<void>();
      final reached = Completer<void>();
      barrier.onCall = (c) async {
        if (c == 'begin:uid-b' && !reached.isCompleted) {
          reached.complete();
          await gate.future;
        }
      };
      final f = flow(crashAfter: 'afterOwnerCleared');
      final purge = f.remove('uid-b', revokeAdmission: false).then<Object?>(
          (_) => null,
          onError: (Object e) => e);
      await reached.future;
      final explicit = f.remove('uid-b').then<Object?>((_) => null,
          onError: (Object e) => e);
      await settle();
      gate.complete();
      expect(await purge, isA<RemoveDataIncompleteException>());
      expect(await explicit, isA<RemoveDataIncompleteException>());
      expect(await flow().revokedUids(), isEmpty);

      expect(await flow().resumePending(), isTrue);
      expect(await flow().revokedUids(), {'uid-b'});
    });

    test('R2-2 a purge joining a running explicit removal never downgrades it',
        () async {
      final gate = Completer<void>();
      final reached = Completer<void>();
      barrier.onCall = (c) async {
        if (c == 'begin:uid-b' && !reached.isCompleted) {
          reached.complete();
          await gate.future;
        }
      };
      final f = flow();
      final explicit = f.remove('uid-b');
      await reached.future;
      final purge = f.remove('uid-b', revokeAdmission: false);
      gate.complete();
      await explicit;
      await purge;
      expect(await f.revokedUids(), {'uid-b'});
    });

    test('R2-2 a delayed resume holds the serialization: an explicit removal '
        'cannot interleave with it and no record is retained afterwards',
        () async {
      await expectLater(flow(crashAfter: 'afterNativeBegin').remove('uid-b'),
          throwsA(isA<RemoveDataIncompleteException>()));
      order.clear();

      final hold = rec.holdOnce(
          (op, key) => op == 'read' && key == RemoveDataFlow.barrierKey);
      final f = flow();
      final resume = f.resumePending();
      await hold.reached.future; // the resume is mid-read of the record

      var explicitDone = false;
      final explicit = f.remove('uid-b').then((_) => explicitDone = true);
      await settle();
      expect(explicitDone, isFalse,
          reason: 'the explicit removal must wait for the resume that already '
              'holds the record');

      hold.release.complete();
      expect(await resume, isTrue);
      await explicit;
      expect(await f.hasPending(), isFalse);
      expect(await f.revokedUids(), {'uid-b'});
      expect(replicaDir(await store.uidHash('uid-b')).existsSync(), isFalse);

      order.clear();
      expect(await f.resumePending(), isTrue);
      expect(order, isEmpty, reason: 'the completed record is not swept again');
    });

    test('R2-2 resume racing an explicit removal before any record exists '
        'neither loses nor duplicates it', () async {
      final f = flow();
      final removal = f.remove('uid-b');
      final resume = f.resumePending();
      await removal;
      expect(await resume, isTrue);
      expect(order.where((c) => c == 'begin:uid-b'), hasLength(1));
      expect(await f.hasPending(), isFalse);
    });
  });

  group('F2: the native barrier seam (production-shaped responses)', () {
    RemoveDataFlow nativeFlow(_Bridge bridge) => RemoveDataFlow(
          store: store,
          scope: _Recording(host, order),
          barrier: CaptureQueueRemoveBarrier(bridge),
          clearOwnerMarker: (_) async {},
        );

    test('a native barrier that cannot name its uid blocks admission: '
        'pendingUid is null, presence is true, nothing is begun or finished',
        () async {
      final bridge = _Bridge()
        ..barrier = const CaptureRemovalBarrier(
            nonce: 'n', uidHash: 'hmac-of-uid', startedAt: '2026-10-08T00:00:00Z');
      final barrier = CaptureQueueRemoveBarrier(bridge);
      expect(await barrier.pendingUid(), isNull, reason: 'no uid is invented');
      expect(await barrier.nativeBarrierPresent(), isTrue);

      expect(await nativeFlow(bridge).resumePending(), isFalse);
      expect(bridge.calls.every((c) => c == 'get'), isTrue);
      expect(bridge.calls, isNot(contains('begin')));
      expect(bridge.calls, isNot(contains('finish')));
    });

    test('no barrier, or an unreadable native answer: only a successful read '
        'of "no barrier" means nothing is pending', () async {
      expect(await nativeFlow(_Bridge()).resumePending(), isTrue);
      final failing = _Bridge()..failGet = true;
      expect(await nativeFlow(failing).resumePending(), isFalse,
          reason: 'cannot read the barrier => cannot admit');
    });
  });
}

Future<String?> storage_(FlutterSecureStorage s, String key) => s.read(key: key);

/// Delegates to the real host while recording the calls the flow makes.
class _Recording implements AccountScopeControl {
  _Recording(this._host, this._log);
  final AccountScopeHost _host;
  final List<String> _log;

  @override
  String? get activeUid => _host.activeUid;

  @override
  Future<void> activate(String uid, {AdmissionAuthority? authority}) =>
      _host.activate(uid, authority: authority);

  @override
  Future<void> detach() async {
    _log.add('detach');
    await _host.detach();
  }

  @override
  Future<void> lock() async {
    _log.add('lock');
    await _host.lock();
  }

  @override
  Future<void> suspendForSwap() => _host.suspendForSwap();
}

/// A native queue bridge answering like production: a barrier record holds only
/// an HMAC of the uid.
class _Bridge implements CaptureQueueBridge {
  CaptureRemovalBarrier? barrier;
  bool failGet = false;
  final List<String> calls = [];

  @override
  Future<CaptureRemovalBarrierRead> getCaptureRemovalBarrier() async {
    calls.add('get');
    if (failGet) throw StateError('native unavailable');
    final b = barrier;
    return b == null
        ? const CaptureRemovalBarrierRead.absent()
        : CaptureRemovalBarrierRead.parse(
            {'nonce': b.nonce, 'uidHash': b.uidHash, 'startedAt': b.startedAt});
  }

  @override
  Future<void> beginCaptureRemoval(String uid) async => calls.add('begin');

  @override
  Future<void> finishCaptureRemoval(String uid) async => calls.add('finish');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
