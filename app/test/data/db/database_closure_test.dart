import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/database_lease.dart';
import 'package:money_companion/data/db/ownership_guard.dart';

// MALI-069n (Batch-4 closure) — lease/maintenance integration, ownership
// generation invalidation, and watcher isolation.
class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'k';
  @override
  Future<String?> readStoredKey() async => 'k';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppDatabase> openDb() =>
      AppDatabase.open(executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());

  late Directory dir;
  late DatabaseLeaseManager lm;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('mali_closure_');
    lm = DatabaseLeaseManager(
        leaseDir: '${dir.path}/leases', intentPath: '${dir.path}/db.maint');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  group('Blocker 1 — cross-isolate secondary admission + file-exclusive maintenance',
      () {
    test('openSecondary is refused (typed) while file-exclusive maintenance intent is active',
        () async {
      final exclusive = await lm.acquireExclusive();
      addTearDown(exclusive.release);
      await expectLater(
        AppDatabase.openSecondary(leaseManager: lm),
        throwsA(isA<DatabaseLeaseUnavailable>()),
      );
    });

    test('file-exclusive maintenance WAITS for an active secondary lease, then proceeds',
        () async {
      final db = await openDb();
      addTearDown(db.close);
      final secondaryLease = await lm.acquireShared(); // an active secondary
      // Maintenance (what a reset/delete uses) cannot proceed while it exists.
      await expectLater(
        db.runExclusiveMaintenance(() async => 1,
            mode: MaintenanceMode.fileExclusive,
            leaseManager: lm,
            exclusiveTimeout: const Duration(milliseconds: 150)),
        throwsA(isA<DatabaseLeaseUnavailable>()),
      );
      // Release the secondary → maintenance now succeeds.
      await secondaryLease.release();
      final result = await db.runExclusiveMaintenance(() async => 42,
          mode: MaintenanceMode.fileExclusive,
          leaseManager: lm,
          exclusiveTimeout: const Duration(seconds: 2));
      expect(result, 42);
    });

    test('a new secondary cannot open once maintenance holds the file lock',
        () async {
      final db = await openDb();
      addTearDown(db.close);
      var admittedDuring = true;
      await db.runExclusiveMaintenance(() async {
        // Inside file-exclusive maintenance, a new secondary is refused.
        try {
          await AppDatabase.openSecondary(leaseManager: lm);
          admittedDuring = true;
        } on DatabaseLeaseUnavailable {
          admittedDuring = false;
        }
      }, mode: MaintenanceMode.fileExclusive, leaseManager: lm);
      expect(admittedDuring, isFalse);
    });

    test('logical maintenance requires no lease manager', () async {
      final db = await openDb();
      addTearDown(db.close);
      final ok = await db.runExclusiveMaintenance(() async => 7);
      expect(ok, 7);
    });
  });

  group('Blocker 3 — cross-isolate ownership generation', () {
    setUp(() => FlutterSecureStorage.setMockInitialValues(
        {'local_data_owner_uid': 'user-A'}));

    test('a job commits while ownership is unchanged', () async {
      final guard = OwnershipGuard();
      final token = await guard.capture();
      expect(token, 'user-A');
      final result = await guard.guardCommit(token, () async => 'committed');
      expect(result, 'committed');
    });

    test('sign-out / ownership change aborts an old-owner job before commit',
        () async {
      final guard = OwnershipGuard();
      final token = await guard.capture(); // captured as user-A
      // Sign-out then a new user is admitted (owner UID rewritten).
      const storage = FlutterSecureStorage();
      await storage.write(key: 'local_data_owner_uid', value: 'user-B');
      expect(await guard.stillOwnedBy(token), isFalse);
      var committed = false;
      final result = await guard.guardCommit(token, () async {
        committed = true;
        return 'x';
      });
      expect(result, isNull); // aborted — the old-user job did NOT commit
      expect(committed, isFalse);
    });

    test('a wipe that clears the owner also invalidates a pending job', () async {
      final guard = OwnershipGuard();
      final token = await guard.capture();
      const storage = FlutterSecureStorage();
      await storage.delete(key: 'local_data_owner_uid');
      expect(await guard.stillOwnedBy(token), isFalse);
    });
  });

  group('Blocker 4 — watcher / repository ownership', () {
    test('closing with a live watcher after an ownership change commits no old rows',
        () async {
      FlutterSecureStorage.setMockInitialValues(
          {'local_data_owner_uid': 'user-A'});
      final db = await openDb();
      final guard = OwnershipGuard();
      final token = await guard.capture();
      // A background job is in flight; ownership changes mid-flight.
      const storage = FlutterSecureStorage();
      await storage.write(key: 'local_data_owner_uid', value: 'user-B');
      // Its guarded write is skipped — no previous-user row is written.
      final wrote = await guard.guardCommit(token, () async {
        await db.customStatement(
            "UPDATE user_settings SET country = 'LEAK';");
        return true;
      });
      expect(wrote, isNull);
      final country = (await db
              .customSelect('SELECT country AS c FROM user_settings;')
              .getSingle())
          .read<String>('c');
      expect(country, isNot('LEAK'));
      await db.close();
    });
  });
}
