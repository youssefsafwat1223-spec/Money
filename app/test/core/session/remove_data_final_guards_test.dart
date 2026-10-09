import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/session/account_scope.dart';
import 'package:money_companion/core/session/admission_authority.dart';
import 'package:money_companion/core/session/remove_data_flow.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/replica_location.dart';
import 'package:money_companion/data/db/replica_store.dart';
import 'package:money_companion/data/db/creation_policy.dart';
import 'f2_fixture.dart';
import 'fake_remove_barrier.dart';
import 'recording_secure_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'same UID activation revoked during queued registry read dispatches no active write',
      () async {
    final f = await F2Fixture.create();
    addTearDown(f.dispose);
    await f.signIn('uid-x');
    var live = true;
    final authority = AdmissionAuthority('uid-x', () => live);
    final hold = f.storage
        .holdOnce((op, key) => op == 'read' && key == ReplicaStore.registryKey);
    final activating = f.host.activate('uid-x', authority: authority);
    final rejected =
        expectLater(activating, throwsA(isA<StaleAdmissionException>()));
    await hold.reached.future;
    live = false;
    final from = f.storage.attempts.length;
    hold.release.complete();
    await rejected;
    expect(
        f.storage.attempts
            .skip(from)
            .where((a) => a.startsWith('write:${ReplicaStore.registryKey}=')),
        isEmpty);
  });

  test(
      'runtime migrating adoption held before copy is revoked and drained by actual removal',
      () async {
    final support = Directory.systemTemp.createTempSync('f2_adopt_guard_');
    final storage = RecordingSecureStorage().install();
    final legacy = ReplicaLocation(
        directory: support.path,
        dbFileName: 'money_companion.sqlite',
        keyName: ReplicaLocation.legacyKeyName);
    final source = await AppDatabase.open(location: legacy);
    await source.close();
    storage.data[kMarkerKey] = 'uid-x';
    final reached = Completer<void>();
    final release = Completer<void>();
    final opened = <String>[];
    var simulateInterruptedMigration = false;
    final store = ReplicaStore(
        appSupportDirectory: support.path,
        opener: (
            {location,
            runMigrations = true,
            creation = const CreationPolicy.unrestricted()}) {
          if (simulateInterruptedMigration) {
            simulateInterruptedMigration = false;
            final reg =
                jsonDecode(storage.data[ReplicaStore.registryKey]!) as Map;
            for (final entry in reg.values) {
              entry['state'] = 'migrating';
              entry['adoptPending'] = true;
            }
            storage.data[ReplicaStore.registryKey] = jsonEncode(reg);
            throw const ReplicaUnavailableException(ReplicaState.migrating);
          }
          opened.add(location!.dbPath);
          return AppDatabase.open(
              location: location,
              runMigrations: runMigrations,
              creation: creation);
        },
        debugAfterAdoptionStep: (step) async {
          if (step == 'beforeCopy' && !reached.isCompleted) {
            reached.complete();
            await release.future;
          }
        });
    final host = AccountScopeHost(
        store: store, initialize: (db, uid) async => const AccountScopeInit());
    addTearDown(() async {
      await host.lock();
      host.dispose();
      await store.closeAll();
      support.deleteSync(recursive: true);
    });
    await store.openReplica('uid-x',
        authority: const AdmissionAuthority.forTest('uid-x'));
    await store.closeAll();
    await store.setState('uid-x', ReplicaState.migrating);
    var live = true;
    final authority = AdmissionAuthority('uid-x', () => live);
    simulateInterruptedMigration = true;
    final activating = host.activate('uid-x', authority: authority);
    final rejected =
        expectLater(activating, throwsA(isA<StaleAdmissionException>()));
    await reached.future;
    live = false;
    final order = <String>[];
    final flow = RemoveDataFlow(
        store: store,
        scope: host,
        barrier: FakeRemoveBarrier(order),
        clearOwnerMarker: (_) async {});
    final removal = flow.remove('uid-x');
    final location = await store.locationFor('uid-x');
    final from = storage.attempts.length;
    final openedFrom = opened.length;
    release.complete();
    await rejected;
    await removal;
    expect(opened.skip(openedFrom), isEmpty);
    expect(
        storage.attempts.skip(from).where((a) =>
            a.startsWith('write:${ReplicaStore.registryKey}=') &&
            a != 'write:${ReplicaStore.registryKey}={}'),
        isEmpty);
    expect(
        storage.attempts
            .skip(from)
            .where((a) => a.startsWith('write:${location.keyName}=')),
        isEmpty);
    expect(Directory(location.directory).existsSync(), isFalse);
    expect(File(legacy.dbPath).existsSync(), isTrue);
  });
}
