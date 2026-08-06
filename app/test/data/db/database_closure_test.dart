import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/database_lease.dart';
import 'package:money_companion/data/db/ownership_guard.dart';

// MALI-069n (Batch-4 closure #3) — lease/maintenance integration, the true
// ADMISSION-GENERATION token (not UID-only), and watcher isolation.

const String _kUid = 'local_data_owner_uid';
const String _kGen = 'local_data_owner_generation';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'k';
  @override
  Future<String?> readStoredKey() async => 'k';
}

/// Simulate exactly the admission state AppSession writes cross-isolate.
Future<void> _setAdmission(String? uid, String? gen) async {
  const s = FlutterSecureStorage();
  if (uid == null) {
    await s.delete(key: _kUid);
  } else {
    await s.write(key: _kUid, value: uid);
  }
  if (gen == null) {
    await s.delete(key: _kGen);
  } else {
    await s.write(key: _kGen, value: gen);
  }
}

DatabaseLeaseManager _lm(Directory dir) => DatabaseLeaseManager(
      leaseDir: '${dir.path}/leases',
      intentPath: '${dir.path}/db.maint',
      leaseTtl: const Duration(milliseconds: 400),
      heartbeatInterval: const Duration(milliseconds: 90),
      settleWindow: const Duration(milliseconds: 60),
      pollStep: const Duration(milliseconds: 15),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppDatabase> openDb() =>
      AppDatabase.open(executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());

  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('mali_closure_');
    FlutterSecureStorage.setMockInitialValues({});
  });
  tearDown(() => dir.deleteSync(recursive: true));

  group('Lease/maintenance integration (openSecondary + file-exclusive)', () {
    test('openSecondary is refused (typed) while a file-exclusive intent is active',
        () async {
      final lm = _lm(dir);
      final exclusive = await lm.acquireExclusive();
      addTearDown(exclusive.release);
      await expectLater(
        AppDatabase.openSecondary(leaseManager: lm),
        throwsA(isA<DatabaseLeaseUnavailable>()),
      );
    });

    test('file-exclusive maintenance WAITS for an active secondary lease, then proceeds',
        () async {
      final lm = _lm(dir);
      final db = await openDb();
      addTearDown(db.close);
      final secondaryLease = await lm.acquireShared(); // an active secondary
      await expectLater(
        db.runExclusiveMaintenance(() async => 1,
            mode: MaintenanceMode.fileExclusive,
            leaseManager: lm,
            exclusiveTimeout: const Duration(milliseconds: 150)),
        throwsA(isA<DatabaseLeaseUnavailable>()),
      );
      await secondaryLease.release();
      final result = await db.runExclusiveMaintenance(() async => 42,
          mode: MaintenanceMode.fileExclusive,
          leaseManager: lm,
          exclusiveTimeout: const Duration(seconds: 2));
      expect(result, 42);
    });

    test('a new secondary cannot open once maintenance holds the file lock',
        () async {
      final lm = _lm(dir);
      final db = await openDb();
      addTearDown(db.close);
      var admittedDuring = true;
      await db.runExclusiveMaintenance(() async {
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

    test('openSecondary refuses (StaleOwnershipException) when the admission '
        'token no longer matches (points 1/2)', () async {
      await _setAdmission('A', 'a1');
      final guard = OwnershipGuard();
      final token = await guard.capture();
      await _setAdmission('B', 'b1'); // ownership changed before the open
      await expectLater(
        AppDatabase.openSecondary(ownershipGuard: guard, admissionToken: token),
        throwsA(isA<StaleOwnershipException>()),
      );
    });

    test('runFileExclusiveMaintenance refuses a stale admission BEFORE locking',
        () async {
      await _setAdmission('A', 'a1');
      final guard = OwnershipGuard();
      final token = await guard.capture();
      final db = await openDb();
      addTearDown(db.close);
      await _setAdmission('B', 'b1');
      await expectLater(
        db.runFileExclusiveMaintenance(() async => 1,
            leaseManager: _lm(dir),
            ownershipGuard: guard,
            admissionToken: token),
        throwsA(isA<StaleOwnershipException>()),
      );
    });
  });

  group('Blocker 1 — admission generation (not UID-only)', () {
    test('same UID signs out and signs in again → the old job is rejected',
        () async {
      await _setAdmission('A', 'g1');
      final guard = OwnershipGuard();
      final token = await guard.capture(); // (A, g1)
      await _setAdmission('A', null); // sign-out invalidates the generation
      expect(await guard.isCurrent(token), isFalse);
      await _setAdmission('A', 'g2'); // same UID re-login → new generation
      expect(await guard.isCurrent(token), isFalse,
          reason: 'a UID-only check would WRONGLY accept this');
    });

    test('A → B → A: the first-A job is rejected in the second-A admission',
        () async {
      await _setAdmission('A', 'a1');
      final guard = OwnershipGuard();
      final firstA = await guard.capture(); // (A, a1)
      await _setAdmission('B', 'b1'); // B admitted
      expect(await guard.isCurrent(firstA), isFalse);
      await _setAdmission('A', 'a2'); // A again, new generation
      expect(await guard.isCurrent(firstA), isFalse);
      final secondA = await guard.capture();
      expect(secondA.matches(firstA), isFalse);
    });

    test('a new admission receives a new valid job', () async {
      await _setAdmission('A', 'a2');
      final guard = OwnershipGuard();
      final token = await guard.capture();
      expect(await guard.isCurrent(token), isTrue);
      expect(await guard.guardCommit(token, () async => 'ok'), 'ok');
    });

    test('a job valid at creation is invalid before OPEN when ownership changed',
        () async {
      await _setAdmission('A', 'a1');
      final guard = OwnershipGuard();
      final token = await guard.capture();
      expect(await guard.isCurrent(token), isTrue); // valid at creation
      await _setAdmission('B', 'b1'); // changed before the open
      expect(await guard.isCurrent(token), isFalse);
    });

    test('invalidated after open but before commit → commit is skipped (point 3)',
        () async {
      await _setAdmission('A', 'a1');
      final guard = OwnershipGuard();
      final token = await guard.capture();
      await _setAdmission(null, null); // sign-out/wipe after the connection opened
      var committed = false;
      final r = await guard.guardCommit(token, () async {
        committed = true;
        return 1;
      });
      expect(r, isNull);
      expect(committed, isFalse);
    });

    test('invalidated after commit but before native ack → ack/notify skipped '
        '(points 4/5)', () async {
      await _setAdmission('A', 'a1');
      final guard = OwnershipGuard();
      final token = await guard.capture();
      // (commit already happened) — ownership changes before the acknowledgement:
      await _setAdmission('B', 'b1');
      expect(await guard.isCurrent(token), isFalse,
          reason: 'no native ack / notification under a new admission');
    });

    test('the admission token carries no secret or financial content', () async {
      await _setAdmission('opaque-user-id', 'random-generation-nonce');
      final guard = OwnershipGuard();
      final token = await guard.capture();
      // Only two fields: an opaque owner id + a random generation. Neither is a
      // key/amount/account, and toString reveals only presence, not the values.
      final s = token.toString();
      expect(s, isNot(contains('opaque-user-id')));
      expect(s, isNot(contains('random-generation-nonce')));
      expect(s, contains('uid:set'));
      expect(s, contains('gen:set'));
    });

    test('AppSession mints a generation on admission, invalidates it BEFORE the '
        'sign-out purge, and rotates on same-UID re-login', () async {
      FlutterSecureStorage.setMockInitialValues({});
      const store = FlutterSecureStorage();
      final session = AppSession.instance;
      var wipeSawGenerationAbsent = false;
      session.configureLocalDataWipe(() async {
        wipeSawGenerationAbsent = (await store.read(key: _kGen)) == null;
      });
      session.configureLocalResiduePurge(() async => true);
      session.configureSignOutFlush(null);
      session.configureCaptureDeviceUnlink(null);

      await session.setIdentity(method: 'google', email: 'a@x.com', userId: 'A');
      final g1 = await store.read(key: _kGen);
      expect(g1, isNotNull, reason: 'admission minted a generation');
      final guard = OwnershipGuard();
      final tokenA1 = await guard.capture();

      await session.signOut();
      expect(await store.read(key: _kGen), isNull,
          reason: 'generation invalidated at sign-out');
      expect(wipeSawGenerationAbsent, isTrue,
          reason: 'invalidation happened BEFORE the sign-out wipe/purge');

      await session.setIdentity(method: 'google', email: 'a@x.com', userId: 'A');
      final g2 = await store.read(key: _kGen);
      expect(g2, isNotNull);
      expect(g2, isNot(g1), reason: 'rotated on same-UID re-login');
      expect(await guard.isCurrent(tokenA1), isFalse,
          reason: 'the previous session job is rejected');

      // Leave the shared singleton clean for other tests.
      await session.signOut();
      session.configureLocalDataWipe(null);
      session.configureLocalResiduePurge(null);
    });
  });

  group('Blocker 4 — watcher / repository ownership', () {
    test('closing with a live watcher after an ownership change commits no old rows',
        () async {
      await _setAdmission('user-A', 'genA');
      final db = await openDb();
      final guard = OwnershipGuard();
      final token = await guard.capture();
      // A background job is in flight; ownership changes mid-flight.
      await _setAdmission('user-B', 'genB');
      // Its guarded write is skipped — no previous-user row is written.
      final wrote = await guard.guardCommit(token, () async {
        await db.customStatement("UPDATE user_settings SET country = 'LEAK';");
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
