import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/core/privacy/consent_authority.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/features/capture/services/capture_device_registration_service.dart';

import '../../core/session/f2_fixture.dart';
import '../../harness/egress_test_support.dart';

// N-R9 (Astra R8 Q9): "no thaw anywhere" is NOT claimed. `resolvePendingDisable`
// is the successor's initialization and may end the process freeze, but only
// AFTER its reconciliation has judged the durable state. While the gate is
// unresolved (reconciliation reads still pending) EFFECTIVE admission stays
// denied: the Boolean freeze set by a prior owner's incomplete withdrawal is
// held, not cleared first. These tests pause the reconciliation's first read and
// check actual admission (admit / permits / permitsNetworkSync), not only the
// Boolean. No timer releases anything.

CloudEgressRecord _rec(String owner, EgressState s, int g) => CloudEgressRecord(
    state: s, ownerUid: owner, transitionGeneration: g, reservedVersion: 1);

String _env(List<CloudEgressRecord> records) => jsonEncode({
      'v': 1,
      'records': {for (final r in records) r.ownerUid: r.toJson()},
    });

class _PauseBeforeReadSlot extends MemorySlot {
  int reads = 0;
  int? pauseAt;
  final reached = Completer<void>();
  final release = Completer<void>();

  @override
  Future<SlotRead> read() async {
    reads++;
    if (reads == pauseAt) {
      reached.complete();
      await release.future;
    }
    return super.read();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestEgress egress;
  late F2Fixture f;

  setUp(() async {
    egress = TestEgress().install();
    f = await F2Fixture.create();
    ConsentAuthority.egressFrozen = false;
  });
  tearDown(() async {
    await f.dispose();
    ConsentAuthority.egressFrozen = false;
  });

  /// Starts [resolvePendingDisable] with the reconciliation's owner read held.
  Future<({Future<void> running, Completer<void> release, Completer<void> reached})>
      startPaused(String uid, {bool cloudOn = false}) async {
    await f.signIn(uid);
    egress.owner = uid;
    final db = f.host.current!.database;
    final repo = DriftUserSettingsRepository(db);
    if (cloudOn) {
      final s = await repo.getSettings();
      await repo.saveSettings(s.copyWith(cloudConsentState: ConsentState.accepted));
    }
    final reached = Completer<void>();
    final release = Completer<void>();
    final service = CaptureDeviceRegistrationService(
      settingsRepository: repo,
      gate: egress.gate,
      readSession: () => (uid: uid, jwt: 'jwt'),
      isCurrentScope: () => identical(f.host.current?.database, db),
      readReplicaOwnerUid: () async {
        if (!reached.isCompleted) {
          reached.complete();
          await release.future;
        }
        return uid;
      },
    );
    final running = service.resolvePendingDisable();
    await reached.future;
    return (running: running, release: release, reached: reached);
  }

  Future<void> expectDenied(String uid) async {
    expect(await egress.gate.permits(owner: uid), isFalse);
    expect(egress.gate.permitsNetworkSync, isFalse);
    await expectLater(egress.gate.admit(owner: uid),
        throwsA(isA<EgressDeniedException>()));
    expect(ConsentAuthority.egressFrozen, isTrue,
        reason: 'the freeze is held, not cleared before reconciliation');
  }

  test(
      'same successor UID: a prior incomplete withdrawal (freeze, durable ON '
      'record, settings OFF) stays denied while the reconciliation is paused',
      () async {
    final body = _env([_rec('uid-x', EgressState.on, 3)]);
    egress.secure.value = body;
    egress.file.value = body;
    ConsentAuthority.egressFrozen = true;
    final p = await startPaused('uid-x');
    await expectDenied('uid-x');
    p.release.complete();
    await p.running;
    // Reconciliation aligned the record DOWN; nothing was widened.
    expect(await egress.gate.permits(owner: 'uid-x'), isFalse);
    final seen = (await egress.gate.store.readOwnerLayers('uid-x')).records;
    expect(seen.every((r) => r.state == EgressState.off), isTrue);
    expect(seen.every((r) => r.transitionGeneration > 3), isTrue);
  });

  test(
      'different successor UID: another owner\'s freeze keeps the successor '
      'denied while the reconciliation is paused', () async {
    final body = _env([
      _rec('uid-x', EgressState.disabling, 3),
      _rec('uid-y', EgressState.on, 1),
    ]);
    egress.secure.value = body;
    egress.file.value = body;
    ConsentAuthority.egressFrozen = true;
    final p = await startPaused('uid-y', cloudOn: true);
    await expectDenied('uid-y');
    p.release.complete();
    await p.running;
    // The old owner's marker is neither adopted nor discarded.
    final x = (await egress.gate.store.readOwnerLayers('uid-x')).records;
    expect(x, [
      _rec('uid-x', EgressState.disabling, 3),
      _rec('uid-x', EgressState.disabling, 3)
    ]);
  });

  test(
      'uncertainty: an unreadable layer keeps admission denied while paused, '
      'after the reconciliation, and a restart; valid evidence recovers it',
      () async {
    final body = _env([_rec('uid-x', EgressState.on, 3)]);
    egress.secure.value = body;
    egress.file.value = body;
    egress.file.failReads = true;
    ConsentAuthority.egressFrozen = true;
    final p = await startPaused('uid-x', cloudOn: true);
    await expectDenied('uid-x');
    p.release.complete();
    await p.running;
    expect(ConsentAuthority.egressFrozen, isTrue);
    expect(await egress.gate.permits(owner: 'uid-x'), isFalse);
    await expectLater(egress.gate.admit(owner: 'uid-x'),
        throwsA(isA<EgressDeniedException>()));
    // No timer thaw.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(ConsentAuthority.egressFrozen, isTrue);
    expect(egress.file.value, body, reason: 'never repaired or rewritten');
    // Valid evidence returns; a fresh initialization (restart) recovers.
    egress.file.failReads = false;
    ConsentAuthority.egressFrozen = false;
    final again = CaptureDeviceRegistrationService(
      settingsRepository: DriftUserSettingsRepository(f.host.current!.database),
      gate: egress.gate,
      readSession: () => (uid: 'uid-x', jwt: 'jwt'),
      readReplicaOwnerUid: () async => 'uid-x',
      isCurrentScope: () => true,
    );
    await again.resolvePendingDisable();
    expect(ConsentAuthority.egressFrozen, isFalse);
    expect(await egress.gate.permits(owner: 'uid-x'), isTrue);
  });

  test('retired initialization cannot allocate OFF against a successor',
      () async {
    await f.signIn('uid-x');
    final secure = _PauseBeforeReadSlot();
    final file = MemorySlot();
    final initial = _env([_rec('uid-x', EgressState.on, 3)]);
    secure.value = initial;
    file.value = initial;
    final gate = CloudEgressGate(
      store: CloudEgressStore.forTesting(secure: secure, file: file),
      activeOwner: () async => 'uid-x',
      resolved: true,
    );
    CloudEgressGate.instance = gate;
    final service = CaptureDeviceRegistrationService(
      settingsRepository: DriftUserSettingsRepository(f.host.current!.database),
      gate: gate,
      readSession: () => (uid: 'uid-x', jwt: 'jwt'),
      readReplicaOwnerUid: () async => 'uid-x',
      isCurrentScope: () => true,
    );
    // First read judges ON against local OFF; the second is alignOff's
    // generation allocation. The provider is retired during that second read.
    secure.pauseAt = 2;
    final running = service.resolvePendingDisable();
    await secure.reached.future;
    service.dispose();
    final successor = _env([
      _rec('uid-x', EgressState.on, 20),
      _rec('uid-y', EgressState.on, 31),
    ]);
    secure.value = successor;
    file.value = successor;
    secure.release.complete();
    await running;
    expect(secure.value, successor);
    expect(file.value, successor);
    expect(secure.writes + file.writes, 0,
        reason: 'retirement revoked this initialization before dispatch');
  });

  for (final uid in ['uid-x', 'uid-y']) {
    for (final uncertain in [false, true]) {
      test('unresolved gate denies $uid during initialization '
          '(uncertain=$uncertain), even without the Boolean freeze', () async {
        egress = TestEgress(resolved: false).install();
        final body = _env([
          _rec('uid-x', EgressState.disabling, 3),
          _rec(uid, EgressState.on, 8),
        ]);
        egress.secure.value = body;
        egress.file.value = uncertain ? 'not json' : body;
        ConsentAuthority.egressFrozen = false;
        final paused = await startPaused(uid, cloudOn: true);
        expect(egress.gate.isResolved, isFalse);
        expect(ConsentAuthority.egressFrozen, isFalse,
            reason: 'denial here comes from the unresolved gate');
        expect(await egress.gate.permits(owner: uid), isFalse);
        expect(egress.gate.permitsNetworkSync, isFalse);
        await expectLater(egress.gate.admit(owner: uid),
            throwsA(isA<EgressDeniedException>()));
        paused.release.complete();
        await paused.running;
        expect(egress.gate.isResolved, isTrue);
        expect(await egress.gate.permits(owner: uid), !uncertain);
        expect(ConsentAuthority.egressFrozen, uncertain);
      });
    }
  }

  // N-R9 (Astra R8 Q7): conservative refusal under corruption stays; it is
  // never completed falsely, never repaired, survives a restart and recovers
  // only when valid evidence returns.
  group('Q7 persistent corruption of a DISABLING withdrawal', () {
    CaptureDeviceRegistrationService fresh(String uid) =>
        CaptureDeviceRegistrationService(
          settingsRepository:
              DriftUserSettingsRepository(f.host.current!.database),
          gate: CloudEgressGate.instance,
          readSession: () => (uid: uid, jwt: 'jwt'),
          readReplicaOwnerUid: () async => uid,
          isCurrentScope: () => true,
        );

    test(
        'a corrupt layer: no false completion, no repair, denied across '
        'restarts; valid evidence returning completes the OFF', () async {
      await f.signIn('uid-x');
      egress.owner = 'uid-x';
      final disabling = _env([_rec('uid-x', EgressState.disabling, 4)]);
      egress.secure.value = disabling;
      egress.file.value = 'not json';
      final secureWrites = egress.secure.writes;
      for (var restart = 0; restart < 3; restart++) {
        ConsentAuthority.egressFrozen = false;
        CloudEgressGate.instance = CloudEgressGate(
          store: CloudEgressStore.forTesting(
              secure: egress.secure, file: egress.file),
          activeOwner: () async => 'uid-x',
          resolved: false,
        );
        await fresh('uid-x').resolvePendingDisable();
        expect(ConsentAuthority.egressFrozen, isTrue,
            reason: 'restart $restart: still frozen');
        expect(await CloudEgressGate.instance.permits(owner: 'uid-x'), isFalse);
        await expectLater(CloudEgressGate.instance.admit(owner: 'uid-x'),
            throwsA(isA<EgressDeniedException>()));
        expect(egress.secure.value, disabling, reason: 'never completed OFF');
        expect(egress.file.value, 'not json', reason: 'never repaired');
        expect(egress.secure.writes, secureWrites);
      }
      // Valid evidence returns (the damaged layer now agrees): the next
      // initialization completes OFF, never a widening.
      egress.file.value = disabling;
      ConsentAuthority.egressFrozen = false;
      await fresh('uid-x').resolvePendingDisable();
      final seen = (await egress.gate.store.readOwnerLayers('uid-x')).records;
      expect(seen.map((r) => r.state), everyElement(EgressState.off));
      expect(seen.every((r) => r.transitionGeneration == 4), isTrue);
      expect(await CloudEgressGate.instance.permits(owner: 'uid-x'), isFalse);
    });

    test(
        'a corrupt layer at disable time: the DISABLING write is refused '
        '(no generation claimed), the freeze stays and the person is told it '
        'was not durable', () async {
      await f.signIn('uid-x');
      egress.owner = 'uid-x';
      final on = _env([_rec('uid-x', EgressState.on, 7)]);
      egress.secure.value = on;
      egress.file.value = 'not json';
      final service = fresh('uid-x');
      await expectLater(
          service.disableCloud(commitLocalOff: () async {}),
          throwsA(isA<CloudDisableException>()));
      expect(egress.secure.value, on, reason: 'unseen authority not replaced');
      expect(egress.file.value, 'not json');
      expect(ConsentAuthority.egressFrozen, isTrue);
      expect(await CloudEgressGate.instance.permits(owner: 'uid-x'), isFalse);
    });
  });
}
