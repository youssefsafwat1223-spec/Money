// SDK event injection uses the real GoTrue broadcast; no production use.
// ignore_for_file: invalid_use_of_internal_member, invalid_use_of_protected_member

import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backup/backup_snapshot_builder.dart';
import 'package:money_companion/core/backup/restore_preparation.dart';
import 'package:money_companion/core/backup/restore_plan.dart';
import 'package:money_companion/core/backup/restore_result.dart';
import 'package:money_companion/core/backup/restore_service.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/core/session/local_read_authority.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/creation_policy.dart';
import 'package:money_companion/data/db/database_access_broker.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/database_lease.dart';
import 'package:money_companion/data/db/ownership_guard.dart';
import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../harness/seed_test_account.dart';
import 'f2_fixture.dart';

// O-BX-1 (Astra R6) — EVERY exclusive-maintenance creator is accounted for in
// the local-read exclusion argument, not only Remove data. The real creators
// are `AppDatabase.runExclusiveMaintenance` / `runFileExclusiveMaintenance`
// (backup restore through `RestoreService`). They are driven here over a real
// encrypted replica, a real lease manager (every intent attempt is counted) and
// the real session singleton. The exclusion must DRAIN a maintenance operation
// that already holds the gate and DENY one that has not yet created its intent,
// so that no maintenance intent appears after the exclusion began and none
// overlaps the published read scope.

const _uid = 'uid-bx1';

class _SpyLeaseManager extends DatabaseLeaseManager {
  _SpyLeaseManager({required super.leaseDir, required super.intentPath});
  int acquireCalls = 0;

  @override
  Future<DatabaseFileLease> acquireExclusive({
    Duration timeout = const Duration(seconds: 10),
  }) {
    acquireCalls++;
    return super.acquireExclusive(timeout: timeout);
  }
}

/// Lets a test hold the Nth admission check (inside the restore's maintenance
/// action) without touching secure storage.
class _GatedGuard extends OwnershipGuard {
  _GatedGuard(this.holdOnCall, this.reached, this.release);
  final int holdOnCall;
  final Completer<void> reached;
  final Completer<void> release;
  int calls = 0;

  @override
  Future<bool> isCurrent(AdmissionToken token) async {
    if (++calls == holdOnCall) {
      reached.complete();
      await release.future;
    }
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late F2Fixture f;
  late LocalReadAuthority authority;
  late DatabaseAccessBroker coordinator;
  late List<SupabaseClient> clients;

  setUp(() async {
    await AppSession.instance.debugResetAuthBinding();
    clients = [];
    coordinator = DatabaseAccessBroker.debugUnregistered();
    f = await F2Fixture.create(
      coordinator: coordinator,
      opener: (
          {location,
          runMigrations = true,
          creation = const CreationPolicy.unrestricted()}) {
        return AppDatabase.open(
            location: location,
            runMigrations: runMigrations,
            creation: creation);
      },
    );
    f.session.configureAccountScope(f.host);
    authority = LocalReadAuthority(store: SecureLocalReadStore());
    f.session.configureLocalRead(authority);
  });

  tearDown(() async {
    f.session.debugLocalReadAwaitPoint = null;
    f.session.configureLocalRead(null);
    await f.session.debugLocalReadIdle;
    await f.session.debugResetAuthBinding();
    await f.dispose();
    for (final c in clients) {
      await c.dispose();
    }
    coordinator.debugDispose();
  });

  Future<AppDatabase> signInWritable() async {
    final sdk = await f.clientFor(_uid);
    clients.add(sdk);
    await f.session.bindSupabaseAuth(sdk);
    await f.session.setIdentity(
        method: 'google', email: '$_uid@example.com', userId: _uid);
    await f.session.finishOnboarding(client: sdk);
    return f.host.current!.database;
  }

  Future<_SpyLeaseManager> spyLeases() async {
    final location = await f.store.activeLocation();
    expect(location, isNotNull);
    return _SpyLeaseManager(
        leaseDir: location!.leaseDir, intentPath: location.maintPath);
  }

  List<String> tree() => [
        for (final e in Directory(f.support.path).listSync(recursive: true))
          p.relative(e.path, from: f.support.path),
      ]..sort();

  Future<void> until(bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) fail('condition never held');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test(
      'a maintenance caller paused BEFORE its intent is refused: the exclusion '
      'never sees, and the caller never creates, an intent', () async {
    final writable = await signInWritable();
    final spy = await spyLeases();
    final gate = Completer<void>();
    // A real in-flight borrow keeps the maintenance in its drain step, i.e.
    // strictly before it would acquire the exclusive lease / publish an intent.
    final borrowed = writable.borrow(() => gate.future);
    var actionRan = false;
    Object? maintenanceError;
    final maintenance = writable
        .runFileExclusiveMaintenance<void>(
          () async => actionRan = true,
          leaseManager: spy,
          drainTimeout: const Duration(seconds: 30),
        )
        .then<void>((_) {}, onError: (Object e) => maintenanceError = e);
    await pumpEventQueue();
    expect(writable.isUnderMaintenance, isTrue);
    expect(spy.acquireCalls, 0, reason: 'still before intent acquisition');

    // The paused caller is released only once the exclusion owns the transition
    // and has drained: the latest point a stale caller could still publish.
    f.session.debugLocalReadAwaitPoint = (point) async {
      if (point == 'exclusion_drained' && !gate.isCompleted) {
        gate.complete();
        await pumpEventQueue(times: 100);
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    };
    final restored = await f.session.restoreLocalReadAccess(host: f.host);
    if (!gate.isCompleted) gate.complete();
    await maintenance;
    await borrowed;

    expect(spy.acquireCalls, 0,
        reason: 'a stale maintenance caller never creates an intent after the '
            'exclusion began');
    expect(actionRan, isFalse);
    expect(maintenanceError, isA<DatabaseLifecycleException>());
    expect(restored, isTrue, reason: 'nothing blocked the verified read scope');
    expect(tree().where((e) => e.endsWith('.maint')), isEmpty);
    expect(f.host.current!.isLocalRead, isTrue);
  });

  test(
      'a maintenance caller QUEUED behind an earlier one is refused, the '
      'running one is awaited, and none overlaps the read scope', () async {
    final writable = await signInWritable();
    final first = await spyLeases();
    final second = await spyLeases();
    final events = <String>[];
    final release = Completer<void>();
    final m1 = writable.runFileExclusiveMaintenance<void>(() async {
      events.add('m1_start');
      await release.future;
      events.add('m1_end');
    }, leaseManager: first);
    await until(() => events.contains('m1_start'));

    Object? secondError;
    final m2 = writable
        .runFileExclusiveMaintenance<void>(() async => events.add('m2_ran'),
            leaseManager: second)
        .then<void>((_) {}, onError: (Object e) => secondError = e);
    await pumpEventQueue();
    expect(second.acquireCalls, 0, reason: 'queued behind m1');

    f.session.debugLocalReadAwaitPoint = (point) async {
      if (point == 'restore_returned') events.add('verified');
    };
    final restoring = f.session.restoreLocalReadAccess(host: f.host).then((v) {
      events.add('published:$v');
      return v;
    });
    await pumpEventQueue(times: 100);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(events, ['m1_start'],
        reason: 'the restoration WAITS for the maintenance that already holds '
            'the gate; it neither overlaps nor finishes before it');

    release.complete();
    expect(await restoring, isTrue);
    await m1;
    await m2;

    expect(events.first, 'm1_start');
    expect(events.indexOf('m1_end'), lessThan(events.indexOf('verified')),
        reason: 'no maintenance action overlaps the published read scope');
    expect(events, isNot(contains('m2_ran')));
    expect(secondError, isA<DatabaseLifecycleException>());
    expect(second.acquireCalls, 0);
    expect(first.acquireCalls, 1);
    expect(tree().where((e) => e.endsWith('.maint')), isEmpty);
  });

  test('close itself drains an in-flight maintenance and refuses new callers',
      () async {
    final db = await AppDatabase.open(executor: NativeDatabase.memory());
    final spy = _SpyLeaseManager(
        leaseDir: p.join(f.support.path, 'x_leases'),
        intentPath: p.join(f.support.path, 'x.maint'));
    Directory(spy.leaseDir).createSync(recursive: true);
    final events = <String>[];
    final release = Completer<void>();
    final running = db.runFileExclusiveMaintenance<void>(() async {
      events.add('start');
      await release.future;
      events.add('end');
    }, leaseManager: spy);
    await until(() => events.contains('start'));
    final closing = db.close().then((_) => events.add('closed'));
    await pumpEventQueue(times: 50);
    expect(events, ['start'], reason: 'close waits for the running action');
    Object? late;
    await db
        .runExclusiveMaintenance<void>(() async => events.add('late'))
        .then<void>((_) {}, onError: (Object e) => late = e);
    expect(late, isA<DatabaseLifecycleException>());
    release.complete();
    await running;
    await closing;
    expect(events, ['start', 'end', 'closed']);
  });

  group('backup restore participates in the session drain', () {
    Future<RestoreServiceFixture> restoreFixture(AppDatabase target) async {
      final source = await seededDb(AppDatabase.open(
          executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore()));
      addTearDown(source.close);
      final plan = RestorePreparation.build(
        snapshot: await BackupSnapshotBuilder(source).build(),
        envelopeVersion: 3,
        sourceBytes: const [1, 2, 3],
        operationId: 'op-bx1',
      );
      return RestoreServiceFixture(RestoreService(target), plan);
    }

    test(
        'a restore inside its maintenance action is awaited by '
        'drainAdmissions and by the local-read restoration', () async {
      final writable = await signInWritable();
      final spy = await spyLeases();
      final fx = await restoreFixture(writable);
      final reached = Completer<void>();
      final release = Completer<void>();
      // 1: admissionIsCurrent, 2: runFileExclusiveMaintenance, 3: inside mutate.
      final guard = _GatedGuard(3, reached, release);
      final events = <String>[];
      final restore = fx.service
          .execute(
            plan: fx.plan,
            leaseManager: spy,
            ownershipGuard: guard,
            admissionToken:
                const AdmissionToken(ownerUid: _uid, generation: 'g1'),
            preparedUserId: _uid,
            currentUserId: () => _uid,
            maintenanceParticipant: f.session.runMaintenanceParticipant,
          )
          .then((r) {
        events.add('restore_done');
        return r;
      });
      await reached.future.timeout(const Duration(seconds: 20));
      expect(spy.acquireCalls, 1);

      final drain = f.session.drainAdmissions().then((_) => events.add('drained'));
      final restoring =
          f.session.restoreLocalReadAccess(host: f.host).then((v) {
        events.add('published:$v');
        return v;
      });
      await pumpEventQueue(times: 100);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(events, isEmpty,
          reason: 'neither the drain nor the transition overtakes the restore');

      release.complete();
      final result = await restore;
      await drain;
      expect(await restoring, isTrue);
      expect(result.outcome, RestoreOutcome.success);
      expect(events.indexOf('restore_done'),
          lessThan(events.indexOf('published:true')));
      expect(events, contains('drained'));
      expect(tree().where((e) => e.endsWith('.maint')), isEmpty);
    });

    test(
        'a restore that starts once the transition began is refused before it '
        'creates an intent; so is one after the read scope was published',
        () async {
      final writable = await signInWritable();
      final spy = await spyLeases();
      final fx = await restoreFixture(writable);
      var ran = 0;
      Object? during;
      f.session.debugLocalReadAwaitPoint = (point) async {
        if (point == 'exclusion_drained') {
          await f.session
              .runMaintenanceParticipant(() async => ran++)
              .then<void>((_) {}, onError: (Object e) => during = e);
        }
      };
      expect(await f.session.restoreLocalReadAccess(host: f.host), isTrue);
      expect(ran, 0);
      expect(during, isA<StaleOwnershipException>());

      Object? after;
      await f.session
          .runMaintenanceParticipant(() async => ran++)
          .then<void>((_) {}, onError: (Object e) => after = e);
      expect(ran, 0);
      expect(after, isA<StaleOwnershipException>());

      final result = await fx.service.execute(
        plan: fx.plan,
        leaseManager: spy,
        maintenanceParticipant: f.session.runMaintenanceParticipant,
      );
      expect(result.outcome, RestoreOutcome.ownershipChanged);
      expect(spy.acquireCalls, 0);
      expect(tree().where((e) => e.endsWith('.maint')), isEmpty);
    });
  });
}

class RestoreServiceFixture {
  RestoreServiceFixture(this.service, this.plan);
  final RestoreService service;
  final RestorePlan plan;
}

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'k';
  @override
  Future<String?> readStoredKey() async => 'k';
}
