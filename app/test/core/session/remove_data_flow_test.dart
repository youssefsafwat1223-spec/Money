import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/session/account_scope.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/core/session/remove_data_flow.dart';
import 'package:money_companion/data/db/replica_store.dart';
import 'package:path/path.dart' as p;

import 'fake_remove_barrier.dart';

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

  RemoveDataFlow flow({String? crashAfter, bool withCleanup = true}) =>
      RemoveDataFlow(
        store: store,
        scope: _Recording(host, order),
        barrier: barrier,
        clearOwnerMarker: () async {
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
    FlutterSecureStorage.setMockInitialValues({});
    order = [];
    barrier = FakeRemoveBarrier(order);
    store = ReplicaStore(appSupportDirectory: support.path);
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
}

Future<String?> storage_(FlutterSecureStorage s, String key) => s.read(key: key);

/// Delegates to the real host while recording the calls the flow makes.
class _Recording implements AccountScopeControl {
  _Recording(this._host, this._log);
  final AccountScopeHost _host;
  final List<String> _log;

  @override
  Future<void> activate(String uid) => _host.activate(uid);

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
}
