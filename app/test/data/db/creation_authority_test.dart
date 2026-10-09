import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/session/admission_authority.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/creation_policy.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/database_lease.dart';
import 'package:money_companion/data/db/replica_location.dart';
import 'package:money_companion/data/db/replica_store.dart';
import 'package:path/path.dart' as p;

import '../../core/session/recording_secure_storage.dart';

// F2 round 2 (R2-3) — creation authority is a capability bound to a uid and an
// admission epoch, verified by EVERY storage layer before its side effect.

const _x = 'uid-x';
const _y = 'uid-y';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory support;
  late RecordingSecureStorage rec;

  setUp(() {
    support = Directory.systemTemp.createTempSync('creation_authority_');
    rec = RecordingSecureStorage().install();
  });
  tearDown(() {
    if (support.existsSync()) support.deleteSync(recursive: true);
  });

  ReplicaLocation ghost() => ReplicaLocation(
        directory: p.join(support.path, 'replicas', 'ghost'),
        dbFileName: 'qirsh.sqlite',
        keyName: 'qirsh.db_key.ghost',
      );

  group('R2-3 AdmissionAuthority', () {
    test('R2-3 requireFor accepts only its own uid while current', () {
      var live = true;
      final a = AdmissionAuthority(_x, () => live, canCreate: true, epoch: 4);
      expect(a.epoch, 4);
      a.requireFor(_x);
      expect(() => a.requireFor(_y), throwsA(isA<StaleAdmissionException>()),
          reason: 'bound to its uid');
      live = false;
      expect(() => a.requireFor(_x), throwsA(isA<StaleAdmissionException>()),
          reason: 'bound to its epoch');
    });
  });

  group('R2-3 CreationPolicy', () {
    test('R2-3 denied refuses; unrestricted allows; authorized is bound to '
        'uid, currentness and canCreate', () {
      expect(() => const CreationPolicy.denied().requireMayCreate(),
          throwsA(isA<DatabaseCreationNotAuthorizedException>()));
      const CreationPolicy.unrestricted().requireMayCreate();

      var live = true;
      final a = AdmissionAuthority(_x, () => live, canCreate: true);
      final ok = CreationPolicy.authorized(a, _x);
      ok.requireMayCreate();
      expect(() => CreationPolicy.authorized(a, _y).requireMayCreate(),
          throwsA(isA<StaleAdmissionException>()));
      live = false;
      expect(ok.requireMayCreate, throwsA(isA<StaleAdmissionException>()));

      final readOnly = AdmissionAuthority(_x, () => true);
      expect(CreationPolicy.authorized(readOnly, _x).requireMayCreate,
          throwsA(isA<DatabaseCreationNotAuthorizedException>()));
    });
  });

  group('R2-3 every layer verifies uid and currentness before its effect', () {
    test('R2-3 the key store mints only for an authority of ITS uid, and checks '
        'again immediately before the write', () async {
      var live = true;
      final y = AdmissionAuthority(_y, () => live, canCreate: true);
      final wrongUid = SecureDatabaseKeyStore(
        databaseExists: () async => false,
        storageKey: 'qirsh.db_key.k1',
        creation: CreationPolicy.authorized(y, _x),
      );
      await expectLater(wrongUid.readOrCreateKey(),
          throwsA(isA<StaleAdmissionException>()));
      expect(rec.attempts, isEmpty);

      final x = AdmissionAuthority(_x, () => live, canCreate: true);
      final revokedMeanwhile = SecureDatabaseKeyStore(
        databaseExists: () async {
          live = false; // revoked between the existence probe and the mint
          return false;
        },
        storageKey: 'qirsh.db_key.k2',
        creation: CreationPolicy.authorized(x, _x),
      );
      await expectLater(revokedMeanwhile.readOrCreateKey(),
          throwsA(isA<StaleAdmissionException>()));
      expect(rec.attempts.where((a) => a.startsWith('write:')), isEmpty);

      final denied = SecureDatabaseKeyStore(
        databaseExists: () async => false,
        storageKey: 'qirsh.db_key.k3',
        creation: const CreationPolicy.denied(),
      );
      await expectLater(denied.readOrCreateKey(),
          throwsA(isA<DatabaseCreationNotAuthorizedException>()));
      expect(rec.attempts, isEmpty);

      final free = SecureDatabaseKeyStore(
          databaseExists: () async => false, storageKey: 'qirsh.db_key.k4');
      expect(await free.readOrCreateKey(), isNotEmpty);
    });

    test('R2-3 AppDatabase.open with an authority of ANOTHER uid creates no '
        'directory, file or key', () async {
      final loc = ghost();
      final y = AdmissionAuthority(_y, () => true, canCreate: true);
      await expectLater(
        AppDatabase.open(
            location: loc, creation: CreationPolicy.authorized(y, _x)),
        throwsA(isA<StaleAdmissionException>()),
      );
      expect(Directory(loc.directory).existsSync(), isFalse);
      expect(rec.attempts.where((a) => a.startsWith('write:')), isEmpty);
    });

    test('R2-3 AppDatabase.open: authority revoked between the existence probe '
        'and the key mint leaves no key, directory or file', () async {
      final loc = ghost();
      var live = true;
      final a = AdmissionAuthority(_x, () => live, canCreate: true);
      await expectLater(
        AppDatabase.open(
          location: loc,
          creation: CreationPolicy.authorized(a, _x),
          databaseFileExists: () async {
            live = false;
            return false;
          },
        ),
        throwsA(isA<StaleAdmissionException>()),
      );
      expect(Directory(loc.directory).existsSync(), isFalse);
      expect(rec.attempts.where((a) => a.startsWith('write:')), isEmpty);
    });

    test('R2-3 an existing-only open (denied) with a stale existence probe '
        'creates nothing', () async {
      final loc = ghost();
      rec.data[loc.keyName] = 'seeded-key-value';
      await expectLater(
        AppDatabase.open(
          location: loc,
          creation: const CreationPolicy.denied(),
          databaseFileExists: () async => true,
        ),
        throwsA(anything),
      );
      expect(Directory(loc.directory).existsSync(), isFalse);
      expect(File(loc.dbPath).existsSync(), isFalse);
    });

    test('R2-3 ReplicaStore refuses an authority of another uid before the '
        'opener, the registry or the key store is reached', () async {
      var opened = 0;
      final s = ReplicaStore(
        appSupportDirectory: support.path,
        opener: ({location, runMigrations = true, creation = const CreationPolicy.unrestricted()}) async {
          opened++;
          return AppDatabase.open(
              location: location, runMigrations: runMigrations, creation: creation);
        },
      );
      await s.uidHash(_x);
      final before = rec.attempts.length;
      final y = AdmissionAuthority(_y, () => true, canCreate: true);
      await expectLater(s.openReplica(_x, authority: y),
          throwsA(isA<StaleAdmissionException>()));
      await expectLater(s.openStaging(_x, authority: y),
          throwsA(isA<StaleAdmissionException>()));
      expect(opened, 0);
      expect(rec.attempts.skip(before), isEmpty);
      expect(Directory(p.join(support.path, 'replicas')).existsSync(), isFalse);
    });

    test('R2-3 an authority revoked INSIDE the opener is refused by the '
        'database layer before the key is minted', () async {
      var live = true;
      final a = AdmissionAuthority(_x, () => live, canCreate: true);
      final s = ReplicaStore(
        appSupportDirectory: support.path,
        opener: ({location, runMigrations = true, creation = const CreationPolicy.unrestricted()}) async {
          live = false; // Remove data accepted while the open was dispatched
          return AppDatabase.open(
              location: location, runMigrations: runMigrations, creation: creation);
        },
      );
      await expectLater(s.openReplica(_x, authority: a),
          throwsA(isA<StaleAdmissionException>()));
      final hash = await s.uidHash(_x);
      expect(rec.attempts.where((a) => a.startsWith('write:qirsh.db_key.')),
          isEmpty);
      expect(rec.data.containsKey('qirsh.db_key.$hash'), isFalse);
      expect(
          Directory(p.join(support.path, 'replicas', hash)).existsSync(), isFalse);
    });
  });

  group('R2-3 removal exclusion with a secondary that never releases', () {
    test('R2-3 the drain times out: removal reports failure and DELETES '
        'NOTHING; the replica stays intact', () async {
      final s = ReplicaStore(
        appSupportDirectory: support.path,
        removalDrainTimeout: const Duration(milliseconds: 300),
      );
      await s.openReplica(_x, authority: const AdmissionAuthority.forTest(_x));
      final loc = await s.locationFor(_x);
      final hash = await s.uidHash(_x);
      final secondary = await DatabaseLeaseManager(
        leaseDir: loc.leaseDir,
        intentPath: loc.maintPath,
      ).acquireShared();

      await expectLater(s.remove(_x), throwsA(isA<DatabaseLeaseUnavailable>()));

      expect(File(loc.dbPath).existsSync(), isTrue);
      expect(rec.data.containsKey('qirsh.db_key.$hash'), isTrue);
      expect((await s.list()).any((e) => e.uidHash == hash), isTrue);
      expect(File(loc.maintPath).existsSync(), isFalse,
          reason: 'the intent is released again so the replica is usable');
      await secondary.release();
      await s.remove(_x); // and a retry completes
      expect(Directory(loc.directory).existsSync(), isFalse);
    });
  });

  group('R2-4 a swap carries the authority', () {
    test('R2-4 swapStaging with a revoked authority mutates nothing', () async {
      final s = ReplicaStore(appSupportDirectory: support.path);
      await s.openReplica(_x, authority: const AdmissionAuthority.forTest(_x));
      await s.beginRebootstrap(_x, 'reset');
      await s.openStaging(_x, authority: const AdmissionAuthority.forTest(_x));
      final hash = await s.uidHash(_x);
      final before = rec.attempts.length;
      var live = false;
      final stale = AdmissionAuthority(_x, () => live, canCreate: true);
      await expectLater(s.swapStaging(_x, authority: stale),
          throwsA(isA<StaleAdmissionException>()));
      expect(rec.attempts.skip(before), isEmpty);
      expect(Directory(p.join(support.path, 'replicas', hash)).existsSync(), isTrue);
      expect(
          Directory(p.join(support.path, 'replicas', '$hash.rb')).existsSync(),
          isTrue);
      expect(
          Directory(p.join(support.path, 'replicas', '$hash.old')).existsSync(),
          isFalse);
      live = true;
      await s.swapStaging(_x, authority: stale); // a current one still swaps
      expect(
          Directory(p.join(support.path, 'replicas', '$hash.old')).existsSync(),
          isTrue);
    });

    test('R2-4 an authority of another uid cannot swap', () async {
      final s = ReplicaStore(appSupportDirectory: support.path);
      await s.openReplica(_x, authority: const AdmissionAuthority.forTest(_x));
      await s.beginRebootstrap(_x, 'reset');
      await s.openStaging(_x, authority: const AdmissionAuthority.forTest(_x));
      await expectLater(
          s.swapStaging(_x,
              authority: const AdmissionAuthority.forTest(_y)),
          throwsA(isA<StaleAdmissionException>()));
    });
  });
}
