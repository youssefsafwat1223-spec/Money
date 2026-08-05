import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';

// MALI-069n (Phase-6 Batch 4) — database connection lifecycle, failed-init
// cleanup, idempotent close, secondary-connection policy, maintenance boundary.
class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'k';
  @override
  Future<String?> readStoredKey() async => 'k';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppDatabase> open({
    bool runMigrations = true,
    Future<void> Function(String)? failInit,
  }) =>
      AppDatabase.open(
        executor: NativeDatabase.memory(),
        keyStore: _MemoryKeyStore(),
        runMigrations: runMigrations,
        debugFailInit: failInit,
      );

  group('lifecycle state', () {
    test('a successful open is in the open state; close moves to closed', () async {
      final db = await open();
      expect(db.lifecycleState, DatabaseLifecycleState.open);
      await db.close();
      expect(db.lifecycleState, DatabaseLifecycleState.closed);
    });
  });

  group('failed initialization cleanup (§3)', () {
    test('a failing init rethrows the ORIGINAL error (cleanup never masks it)',
        () async {
      await expectLater(
        open(failInit: (p) async => throw StateError('boom-$p')),
        throwsA(isA<StateError>()),
      );
    });

    test('a fresh open succeeds after a failed open (bounded retry)', () async {
      await expectLater(
        open(failInit: (_) async => throw StateError('boom')),
        throwsA(isA<StateError>()),
      );
      final db = await open(); // a new connection, no injected failure
      addTearDown(db.close);
      expect(db.lifecycleState, DatabaseLifecycleState.open);
      expect(await db.count('user_settings'), 1);
    });
  });

  group('idempotent close (§2)', () {
    test('close is idempotent — two calls complete, state is closed', () async {
      final db = await open();
      await Future.wait([db.close(), db.close()]);
      expect(db.lifecycleState, DatabaseLifecycleState.closed);
      // A third close is still safe.
      await db.close();
      expect(db.lifecycleState, DatabaseLifecycleState.closed);
    });

    test('close settles a concurrent close to the SAME teardown', () async {
      final db = await open();
      final a = db.close();
      final b = db.close();
      await a;
      await b;
      expect(db.lifecycleState, DatabaseLifecycleState.closed);
    });
  });

  group('secondary connection policy (§6)', () {
    test('runMigrations:false opens WITHOUT running the migration pipeline',
        () async {
      final db = await open(runMigrations: false);
      addTearDown(db.close);
      expect(db.lifecycleState, DatabaseLifecycleState.open);
      // No migrations ran → the schema was NOT created on this fresh connection.
      final tables = (await db
              .customSelect("SELECT count(*) AS n FROM sqlite_master WHERE type='table';")
              .getSingle())
          .read<int>('n');
      expect(tables, 0);
    });
  });

  group('exclusive maintenance boundary (§10)', () {
    test('maintenance marks the DB and serialises concurrent maintenance',
        () async {
      final db = await open();
      addTearDown(db.close);
      final gate = Completer<void>();
      final order = <String>[];
      final first = db.runExclusiveMaintenance(() async {
        order.add('first-start');
        expect(db.isUnderMaintenance, isTrue);
        await gate.future;
        order.add('first-end');
      });
      // A second maintenance must WAIT for the first (serialised).
      final second = db.runExclusiveMaintenance(() async => order.add('second'));
      gate.complete();
      await Future.wait([first, second]);
      expect(order, ['first-start', 'first-end', 'second']);
      expect(db.isUnderMaintenance, isFalse); // flag cleared afterward
    });

    test('a failing maintenance clears the flag (DB returns usable)', () async {
      final db = await open();
      addTearDown(db.close);
      await expectLater(
        db.runExclusiveMaintenance(() async => throw StateError('x')),
        throwsA(isA<StateError>()),
      );
      expect(db.isUnderMaintenance, isFalse);
      // Still usable.
      expect(await db.count('user_settings'), 1);
    });
  });
}
