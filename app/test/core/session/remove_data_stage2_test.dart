import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/session/rebootstrap_service.dart';
import 'package:money_companion/core/session/replica_recovery.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_lease.dart';
import 'package:money_companion/data/db/creation_policy.dart';
import 'package:money_companion/core/session/admission_authority.dart';

import 'f2_fixture.dart';

class _Capture implements RebootstrapCaptureControl {
  @override
  Set<String> get deferredCaptureIds => {};
  @override
  Future<void> hold() async {}
  @override
  Future<void> resume(Set<String> committed) async {}
}

class _Lookup implements LedgerServerLookup {
  @override
  Future<Map<String, Map<String, dynamic>>> byClientRequestId(
          Set<String> ids) async =>
      {};
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late F2Fixture f;
  setUp(() async => f = await F2Fixture.create());
  tearDown(() async => f.dispose());

  test(
      'tracked actual primary open drains before removal deletes its directory',
      () async {
    await f.dispose();
    final reached = Completer<void>();
    final release = Completer<void>();
    var delay = false;
    var nativeOpened = false;
    f = await F2Fixture.create(opener: (
        {location,
        runMigrations = true,
        creation = const CreationPolicy.unrestricted()}) async {
      final db = await AppDatabase.open(
          location: location,
          runMigrations: runMigrations,
          creation: creation,
          databaseFileExists: () async {
            final exists = await File(location!.dbPath).exists();
            if (delay && !reached.isCompleted) {
              reached.complete();
              await release.future;
            }
            return exists;
          });
      if (delay) nativeOpened = true;
      return db;
    });
    await f.signIn('uid-y');
    await f.signIn('uid-x');
    final location = await f.store.locationFor('uid-x');
    await f.store.closeReplica('uid-x');
    delay = true;
    final opening = f.store.openReplica('uid-x');
    final rejected =
        expectLater(opening, throwsA(isA<StaleAdmissionException>()));
    await reached.future;
    var removed = false;
    final removal =
        f.session.removeDataFromDevice().then((_) => removed = true);
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (
        !f.order.contains('begin:uid-x') && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(f.order, contains('begin:uid-x'));
    expect(removed, isFalse);
    expect(File(location.dbPath).existsSync(), isTrue);
    release.complete();
    await rejected;
    expect(nativeOpened, isTrue,
        reason:
            'real connection completed then tracked guard closed it before deletion');
    await removal;
    expect(Directory(location.directory).existsSync(), isFalse);
    expect(await f.artifactsOf('uid-y'), ['dir', 'key', 'registry']);
  });

  test(
      'actual flow preserves a live same-PID different-token secondary until close',
      () async {
    await f.signIn('uid-y');
    final yKey = f.storage.data[(await f.store.locationFor('uid-y')).keyName];
    await f.signIn('uid-x');
    final location = await f.store.locationFor('uid-x');
    AppDatabase.dropProcessLiveness(location);
    final manager = DatabaseLeaseManager(
        leaseDir: location.leaseDir,
        intentPath: location.maintPath,
        instanceToken: 'background-isolate-token',
        settleWindow: const Duration(milliseconds: 5),
        pollStep: const Duration(milliseconds: 5));
    final secondary = await AppDatabase.openSecondary(
        location: location, leaseManager: manager);
    addTearDown(secondary.close);
    final live = await AppDatabase.initProcessLiveness(location: location);
    expect(live.acquiredExclusive, isTrue);
    expect(manager.debugLiveLeaseCount(), 1);
    var completed = false;
    final removal =
        f.session.removeDataFromDevice().then((_) => completed = true);
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!File(location.maintPath).existsSync() &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(File(location.maintPath).existsSync(), isTrue);
    expect(completed, isFalse);
    expect(File(location.dbPath).existsSync(), isTrue);
    expect(manager.debugLiveLeaseCount(), 1);
    await expectLater(
        AppDatabase.openSecondary(location: location, leaseManager: manager),
        throwsA(isA<DatabaseLeaseUnavailable>()));
    await secondary.close();
    await removal;
    expect(Directory(location.directory).existsSync(), isFalse);
    expect(await f.artifactsOf('uid-y'), ['dir', 'key', 'registry']);
    expect(f.storage.data[(await f.store.locationFor('uid-y')).keyName], yKey);
    await expectLater(
        AppDatabase.openSecondary(location: location, leaseManager: manager),
        throwsA(isA<DatabaseLeaseUnavailable>()));
    expect(Directory(location.directory).existsSync(), isFalse);
  });

  test(
      'actual rebootstrap paused on staging key loses authority to actual removal',
      () async {
    await f.signIn('uid-y');
    final yKey = f.storage.data[(await f.store.locationFor('uid-y')).keyName];
    await f.signIn('uid-x');
    final hash = await f.hash('uid-x');
    final hold = f.storage
        .holdOnce((op, key) => op == 'write' && key == 'qirsh.db_key.$hash.rb');
    var readmits = 0;
    final service = RebootstrapService(
        store: f.store,
        capture: _Capture(),
        scope: f.scope,
        bootstrapFresh: (fresh, uid) async {},
        lookup: _Lookup(),
        removeData: (uid) => f.flow.remove(uid),
        maintenanceAuthority: f.session.maintenanceAuthority,
        readmit: (uid, authority) async => readmits++);
    final rebuilding = service.run('uid-x', reason: 'reset');
    await hold.reached.future;
    final removal = f.session.removeDataFromDevice();
    final from = f.storage.attempts.length;
    hold.release.complete();
    expect(await rebuilding, RebootstrapOutcome.notNeeded);
    await removal;
    expect(readmits, 0);
    expect(await f.artifactsOf('uid-x'), isEmpty);
    expect(await f.artifactsOf('uid-y'), ['dir', 'key', 'registry']);
    expect(f.storage.data[(await f.store.locationFor('uid-y')).keyName], yKey);
    expect(
        f.storage.attempts
            .skip(from)
            .where((a) => a.startsWith('write:qirsh.db_key.')),
        isEmpty);
  });
}
