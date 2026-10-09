import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/session/admission_authority.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/creation_policy.dart';
import 'package:money_companion/data/db/database_lease.dart';
import 'package:money_companion/data/db/replica_store.dart';

import '../../core/session/recording_secure_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory support;
  late RecordingSecureStorage storage;
  final stores = <ReplicaStore>[];
  setUp(() {
    support = Directory.systemTemp.createTempSync('f2_stage2_');
    storage = RecordingSecureStorage().install();
  });
  tearDown(() async {
    for (final store in stores) {
      await store.closeAll();
      final location = await store.locationFor('uid-x');
      AppDatabase.dropProcessLiveness(location);
    }
    stores.clear();
    support.deleteSync(recursive: true);
  });

  ReplicaStore store({ReplicaOpener? opener}) {
    final result =
        ReplicaStore(appSupportDirectory: support.path, opener: opener);
    stores.add(result);
    return result;
  }

  Future<void> existingReplica() async {
    final original = store();
    await original.openReplica('uid-x',
        authority: const AdmissionAuthority.forTest('uid-x'));
    await original.closeAll();
  }

  test(
      'existing-only open with file and key but absent registry refuses before opener or registry creation',
      () async {
    await existingReplica();
    storage.data.remove(ReplicaStore.registryKey);
    var opens = 0;
    final checked = store(opener: (
        {location,
        runMigrations = true,
        creation = const CreationPolicy.unrestricted()}) {
      opens++;
      return AppDatabase.open(
          location: location, runMigrations: runMigrations, creation: creation);
    });
    final location = await checked.locationFor('uid-x');
    final key = storage.data[location.keyName];
    final bytes = File(location.dbPath).readAsBytesSync();
    final from = storage.attempts.length;
    await expectLater(
        checked.openReplica('uid-x'), throwsA(isA<ReplicaMissingException>()));
    expect(opens, 0);
    expect(storage.attempts.skip(from).where((a) => a.startsWith('write:')),
        isEmpty);
    expect(storage.data[location.keyName], key);
    expect(File(location.dbPath).readAsBytesSync(), orderedEquals(bytes));
  });

  test(
      'existing-only policy retains live authority at the actual database opener boundary',
      () async {
    await existingReplica();
    var live = true;
    final authority = AdmissionAuthority('uid-x', () => live);
    final checked = store(opener: (
        {location,
        runMigrations = true,
        creation = const CreationPolicy.unrestricted()}) {
      expect(creation.mayEverCreate, isFalse);
      live = false;
      return AppDatabase.open(
              location: location,
              runMigrations: runMigrations,
              creation: creation)
          .then((db) async {
        await db.close();
        fail('lower database layer opened with revoked authority');
      });
    });
    final from = storage.attempts.length;
    await expectLater(checked.openReplica('uid-x', authority: authority),
        throwsA(isA<StaleAdmissionException>()));
    expect(storage.attempts.skip(from).where((a) => a.startsWith('write:')),
        isEmpty);
  });

  test(
      'existing-only authority revoked during key read is checked before native connection initialization',
      () async {
    await existingReplica();
    var live = true;
    final authority = AdmissionAuthority('uid-x', () => live);
    final checked = store(opener: (
        {location,
        runMigrations = true,
        creation = const CreationPolicy.unrestricted()}) {
      storage.gate = (op, key) async {
        if (op == 'read' && key == location!.keyName) live = false;
      };
      return AppDatabase.open(
              location: location,
              runMigrations: runMigrations,
              creation: creation)
          .then((db) async {
        await db.close();
        fail('lower database layer opened after key read revoked authority');
      });
    });
    await expectLater(checked.openReplica('uid-x', authority: authority),
        throwsA(isA<StaleAdmissionException>()));
    storage.gate = null;
  });
  for (final vanish in [false, true]) {
    test(
        'queued registry mutation guards ${vanish ? "vanished entry" : "revoked authority"} after read',
        () async {
      await existingReplica();
      var opened = false;
      var live = true;
      final checked = store(opener: (
          {location,
          runMigrations = true,
          creation = const CreationPolicy.unrestricted()}) async {
        final db = await AppDatabase.open(
            location: location,
            runMigrations: runMigrations,
            creation: creation);
        opened = true;
        return db;
      });
      final hold = storage.holdOnce((op, key) =>
          opened && op == 'read' && key == ReplicaStore.registryKey);
      final authority =
          AdmissionAuthority('uid-x', () => live, canCreate: false);
      final opening = checked.openReplica('uid-x', authority: authority);
      final outcome = expectLater(
          opening,
          throwsA(vanish
              ? isA<ReplicaMissingException>()
              : isA<StaleAdmissionException>()));
      await hold.reached.future;
      if (vanish) {
        storage.data.remove(ReplicaStore.registryKey);
      } else {
        live = false;
      }
      final from = storage.attempts.length;
      hold.release.complete();
      await outcome;
      expect(
          storage.attempts
              .skip(from)
              .where((a) => a.startsWith('write:${ReplicaStore.registryKey}=')),
          isEmpty);
      if (vanish) {
        expect(storage.data.containsKey(ReplicaStore.registryKey), isFalse);
      }
    });
  }
  test(
      'actual removal refuses a live external process lock and preserves all artifacts',
      () async {
    await existingReplica();
    final checked = store();
    final location = await checked.locationFor('uid-x');
    AppDatabase.dropProcessLiveness(location);
    final ready = File('${support.path}/ready');
    final helper = File('${support.path}/live_helper.dart')
      ..writeAsStringSync(r'''import 'dart:async';
import 'dart:io';
void main(List<String> a) {
  final lock = File(a[0]).openSync(mode: FileMode.write);
  lock.lockSync(FileLock.exclusive);
  Directory(a[1]).createSync();
  File('${a[1]}/live.lease').writeAsStringSync('live-token\n$pid\nlive-instance');
  File(a[2]).writeAsStringSync('ready');
  Timer.periodic(const Duration(seconds: 1), (_) {});
}
''');
    final child = await Process.start('dart',
        [helper.path, location.plockPath, location.leaseDir, ready.path]);
    addTearDown(() async {
      child.kill(ProcessSignal.sigkill);
      await child.exitCode;
    });
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (!ready.existsSync() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(ready.existsSync(), isTrue);
    final key = storage.data[location.keyName];
    final registry = storage.data[ReplicaStore.registryKey];
    final from = storage.attempts.length;
    await expectLater(
        checked.remove('uid-x'), throwsA(isA<DatabaseLeaseUnavailable>()));
    expect(File(location.dbPath).existsSync(), isTrue);
    expect(File('${location.leaseDir}/live.lease').existsSync(), isTrue);
    expect(storage.data[location.keyName], key);
    expect(storage.data[ReplicaStore.registryKey], registry);
    expect(
        storage.attempts
            .skip(from)
            .where((a) => a.startsWith('delete:') || a.startsWith('write:')),
        isEmpty);
    child.kill(ProcessSignal.sigkill);
    await child.exitCode;
    await checked.remove('uid-x');
    expect(Directory(location.directory).existsSync(), isFalse);
    expect(storage.data.containsKey(location.keyName), isFalse);
    expect(storage.data[ReplicaStore.registryKey], '{}');
  });
}
