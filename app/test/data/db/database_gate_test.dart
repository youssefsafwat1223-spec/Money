import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';

// MALI-069n (Batch-4 closure) — the enforceable borrow/maintenance gate,
// secondary admission, typed busy taxonomy, and stream/provider ownership.
class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'k';
  @override
  Future<String?> readStoredKey() async => 'k';
}

Future<AppDatabase> openDb() => AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Blocker 1 — enforceable borrow/maintenance gate', () {
    test('a borrow is rejected (typed) after close', () async {
      final db = await openDb();
      await db.close();
      await expectLater(
        db.borrow(() async => 1),
        throwsA(predicate((e) =>
            e is DatabaseLifecycleException &&
            e.reason == DatabaseLifecycleFailure.closed)),
      );
    });

    test('maintenance waits for an active borrow to drain before running',
        () async {
      final db = await openDb();
      addTearDown(db.close);
      final borrowGate = Completer<void>();
      final order = <String>[];
      final borrow = db.borrow(() async {
        order.add('borrow-start');
        await borrowGate.future;
        order.add('borrow-end');
      });
      final maint = db.runExclusiveMaintenance(() async => order.add('maint'));
      await Future<void>.delayed(Duration.zero);
      // Maintenance must NOT have run while the borrow is active.
      expect(order, ['borrow-start']);
      borrowGate.complete();
      await Future.wait([borrow, maint]);
      expect(order, ['borrow-start', 'borrow-end', 'maint']);
    });

    test('a NEW borrow is queued while maintenance holds the gate', () async {
      final db = await openDb();
      addTearDown(db.close);
      final maintGate = Completer<void>();
      final order = <String>[];
      final maint = db.runExclusiveMaintenance(() async {
        order.add('maint-start');
        await maintGate.future;
        order.add('maint-end');
      });
      await Future<void>.delayed(Duration.zero);
      final queued = db.borrow(() async => order.add('queued-borrow'));
      await Future<void>.delayed(Duration.zero);
      expect(order, ['maint-start']); // borrow is queued, not run
      maintGate.complete();
      await Future.wait([maint, queued]);
      expect(order, ['maint-start', 'maint-end', 'queued-borrow']);
    });

    test('draining is bounded — a stuck borrow yields maintenanceTimeout',
        () async {
      final db = await openDb();
      addTearDown(db.close);
      final stuck = Completer<void>();
      // ignore: unawaited_futures
      db.borrow(() => stuck.future); // never completes within the timeout
      await Future<void>.delayed(Duration.zero);
      await expectLater(
        db.runExclusiveMaintenance(() async => 1,
            drainTimeout: const Duration(milliseconds: 50)),
        throwsA(predicate((e) =>
            e is DatabaseLifecycleException &&
            e.reason == DatabaseLifecycleFailure.maintenanceTimeout)),
      );
      stuck.complete();
    });

    test('a recoverable maintenance failure restores the usable state',
        () async {
      final db = await openDb();
      addTearDown(db.close);
      await expectLater(
        db.runExclusiveMaintenance(() async => throw StateError('x')),
        throwsA(isA<StateError>()),
      );
      expect(db.lifecycleState, DatabaseLifecycleState.open);
      expect(await db.borrow(() => db.count('user_settings')), 1);
    });

    test('an unrecoverable maintenance yields recoveryRequired', () async {
      final db = await openDb();
      addTearDown(db.close);
      await expectLater(
        db.runExclusiveMaintenance(() async =>
            throw const DatabaseLifecycleException(
                DatabaseLifecycleFailure.recoveryRequired)),
        throwsA(isA<DatabaseLifecycleException>()),
      );
      expect(db.lifecycleState, DatabaseLifecycleState.recoveryRequired);
      // No new borrow may attach to a recovery-required database.
      await expectLater(
          db.borrow(() async => 1), throwsA(isA<DatabaseLifecycleException>()));
    });

    test('two maintenance operations serialise', () async {
      final db = await openDb();
      addTearDown(db.close);
      final order = <String>[];
      final a = db.runExclusiveMaintenance(() async {
        order.add('a-start');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        order.add('a-end');
      });
      final b = db.runExclusiveMaintenance(() async => order.add('b'));
      await Future.wait([a, b]);
      expect(order, ['a-start', 'a-end', 'b']);
    });
  });

  group('Blocker 2 — secondary admission', () {
    test('admitsSecondary is true only when open + not under maintenance',
        () async {
      final db = await openDb();
      expect(db.admitsSecondary, isTrue);
      final gate = Completer<void>();
      final maint = db.runExclusiveMaintenance(() => gate.future);
      await Future<void>.delayed(Duration.zero);
      expect(db.admitsSecondary, isFalse); // quiescing for maintenance
      gate.complete();
      await maint;
      expect(db.admitsSecondary, isTrue);
      await db.close();
      expect(db.admitsSecondary, isFalse);
    });

    test(
        'openSecondary is refused (typed) while the owner is under maintenance',
        () async {
      final db = await openDb();
      addTearDown(db.close);
      final gate = Completer<void>();
      final maint = db.runExclusiveMaintenance(() => gate.future);
      await Future<void>.delayed(Duration.zero);
      await expectLater(
        AppDatabase.openSecondary(owner: db),
        throwsA(isA<DatabaseLifecycleException>()),
      );
      gate.complete();
      await maint;
    });
  });

  group('Blocker 3 — typed busy taxonomy', () {
    test('SQLITE_BUSY / SQLITE_LOCKED map to a retryable busy error', () {
      expect(
          mapDatabaseBusy(
              SqliteException(extendedResultCode: 5, message: 'busy')),
          isA<DatabaseBusyException>());
      expect(
          mapDatabaseBusy(
              SqliteException(extendedResultCode: 6, message: 'locked')),
          isA<DatabaseBusyException>());
      expect(
          mapDatabaseBusy(SqliteException(
              extendedResultCode: 261, message: 'busy_recovery')),
          isA<DatabaseBusyException>());
      expect(
          mapDatabaseBusy(
                  SqliteException(extendedResultCode: 5, message: 'busy'))!
              .isRetryable,
          isTrue);
    });

    test('a non-busy error is never misclassified', () {
      expect(
          mapDatabaseBusy(
              SqliteException(extendedResultCode: 1, message: 'generic')),
          isNull);
      expect(mapDatabaseBusy(StateError('nope')), isNull);
    });

    test('runWithBusyRetry retries bounded, then throws the TYPED busy error',
        () async {
      final db = await openDb();
      addTearDown(db.close);
      var attempts = 0;
      await expectLater(
        db.runWithBusyRetry(() async {
          attempts++;
          throw SqliteException(extendedResultCode: 5, message: 'busy');
        }, maxAttempts: 3),
        throwsA(isA<DatabaseBusyException>()),
      );
      expect(attempts, 3);
    });

    test(
        'runWithBusyRetry succeeds after transient busy; rethrows non-busy raw',
        () async {
      final db = await openDb();
      addTearDown(db.close);
      var n = 0;
      final ok = await db.runWithBusyRetry(() async {
        if (++n < 2) {
          throw SqliteException(extendedResultCode: 5, message: 'busy');
        }
        return 'done';
      });
      expect(ok, 'done');
      await expectLater(
        db.runWithBusyRetry(() async => throw StateError('other')),
        throwsA(isA<StateError>()), // non-busy: original, unchanged
      );
    });
  });

  group('Blocker 4 — stream/provider ownership', () {
    test(
        'a non-owning provider container disposal does NOT close the shared DB',
        () async {
      final db = await openDb();
      addTearDown(db.close);
      final container = ProviderContainer(
        overrides: [appDatabaseProvider.overrideWithValue(db)],
      );
      // Read it through the container, then dispose the container.
      expect(container.read(appDatabaseProvider), same(db));
      container.dispose();
      // The provider is only a holder — it must not have closed what it doesn't own.
      expect(db.lifecycleState, isNot(DatabaseLifecycleState.closed));
      expect(await db.count('user_settings'), 1);
    });

    test('closing with a live watcher completes cleanly (no use-after-close)',
        () async {
      final db = await openDb();
      final events = <int>[];
      final sub = db
          .customSelect('SELECT count(*) AS n FROM user_settings;')
          .watch()
          .listen((rows) => events.add(rows.first.read<int>('n')),
              onError: (_) {}); // must not crash the test on close
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(events, isNotEmpty); // it emitted while open
      final countBeforeClose = events.length;
      // Closing while the watcher is live must complete without throwing.
      await db.close();
      expect(db.lifecycleState, DatabaseLifecycleState.closed);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      // No NEW rows are emitted from the closed executor.
      expect(events.length, countBeforeClose);
      await sub.cancel();
    });
  });
}
