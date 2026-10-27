import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';
import '../../harness/native_enable_sim.dart';
import '../../harness/paused_egress_support.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/core/session/admission_authority.dart';
import 'package:money_companion/core/session/consent_capability.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';

import '../../harness/consent_session_support.dart';
import 'f2_fixture.dart';

// The explicit consent operation's version RESERVATION: allocation metadata that
// is strictly above the local history, the device watermark and the verified
// native frontier; it changes no consent state, it is consumed by the typed
// choice committing at exactly that version, and it never decreases.

class _NestedRepository extends DriftUserSettingsRepository {
  _NestedRepository(super.database);
  bool nested = false;
  @override
  Future<void> beforeConsentChoice(
      ConsentCapability capability, ConsentChoices choices) async {
    if (!nested) {
      nested = true;
      await saveConsentChoice(capability,
          const ConsentChoices(cloud: ConsentState.declined));
    }
  }

}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late F2Fixture f;
  late ConsentCapability capability;
  late DriftUserSettingsRepository repo;

  setUp(() async {
    f = await F2Fixture.create();
    capability = (await freshSignIn(f, 'uid-x'))!;
    repo = DriftUserSettingsRepository(f.host.current!.database);
  });
  tearDown(() async {
    f.session.debugResetAdmissionState();
    await f.dispose();
  });

  Future<({int watermark, int reserved})> marks() async {
    final row = await f.host.current!.database
        .customSelect(
            'SELECT watermark, reserved FROM consent_version_watermark')
        .getSingleOrNull();
    return (
      watermark: row?.read<int>('watermark') ?? 0,
      reserved: row?.read<int>('reserved') ?? 0
    );
  }

  test(
      'V is above the verified frontier, changes no consent and is consumed '
      'only by its own operation, at exactly V', () async {
    final before = await repo.getSettings();
    expect(before.consentVersion, 0);
    final v = await repo.reserveConsentVersion(capability,
        verifiedFrontier: 2, operationId: 'op-a');
    expect(v, 3);
    final during = await repo.getSettings();
    expect(during.cloudConsentState, ConsentState.unset);
    expect(during.consentVersion, 0);
    expect(during.cloudConsentAt, isNull);
    expect((await marks()).reserved, 3);
    // Another operation's reserved commit is refused and writes nothing.
    await expectLater(
        repo.saveReservedConsentChoice(
            capability, const ConsentChoices(cloud: ConsentState.accepted),
            version: 3, operationId: 'op-b'),
        throwsA(isA<StaleAdmissionException>()));
    expect((await repo.getSettings()).cloudConsentState, ConsentState.unset);
    final saved = await repo.saveReservedConsentChoice(
        capability, const ConsentChoices(cloud: ConsentState.accepted),
        version: 3, operationId: 'op-a');
    expect(saved.cloudConsentVersion, 3);
    expect(saved.cloudProcessingEnabled, isTrue);
    expect(await marks(), (watermark: 3, reserved: 0));
  });

  test(
      'any other consent change allocates above the reservation and '
      'invalidates it: the enable can no longer commit below it', () async {
    expect(
        await repo.reserveConsentVersion(capability,
            verifiedFrontier: 2, operationId: 'op-a'),
        3);
    final declined = await repo.saveConsentChoice(
        capability, const ConsentChoices(cloud: ConsentState.declined));
    expect(declined.cloudConsentVersion, 4, reason: 'above the reservation');
    expect(await marks(), (watermark: 4, reserved: 0));
    await expectLater(
        repo.saveReservedConsentChoice(
            capability, const ConsentChoices(cloud: ConsentState.accepted),
            version: 3, operationId: 'op-a'),
        throwsA(isA<StaleAdmissionException>()));
    expect((await repo.getSettings()).cloudConsentState, ConsentState.declined);
  });

  test(
      'the watermark never decreases: a later reservation is above it even '
      'with a lower frontier', () async {
    expect(
        await repo.reserveConsentVersion(capability,
            verifiedFrontier: 5, operationId: 'a'),
        6);
    expect(
        await repo.reserveConsentVersion(capability,
            verifiedFrontier: 0, operationId: 'b'),
        7);
    expect(
        await repo.reserveConsentVersion(capability,
            verifiedFrontier: 1, operationId: 'c'),
        8);
    expect((await marks()).watermark, 8);
  });

  Future<({PendingEnableCommitProof proof, EgressRig rig, NativeEnableSim sim})>
      resumeProof(ConsentCapability current, {String op = 'op-a', int version = 3}) async {
    final rig = EgressRig();
    final sim = NativeEnableSim();
    NativeCaptureBridge.debugTreatHostAsNative = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('money_companion/native_capture'), sim.handle);
    addTearDown(() {
      NativeCaptureBridge.debugTreatHostAsNative = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('money_companion/native_capture'), null);
    });
    final binding = CloudEgressEnableBinding(operationId: kSimOperationId,
        transitionGeneration: 30, reservedVersion: version,
        ownerGeneration: sim.ownerGeneration, ownerEpoch: sim.ownerEpoch);
    final pending = PendingEnableRecord(ownerUid: current.uid,
        transitionGeneration: 30, reservedVersion: version, localOperationId: op, binding: binding);
    await rig.gate.beginPendingEnable(pending);
    final on = rigRecord(EgressState.on, 30, version, current.uid);
    rig.secure.value = rigEnvelope(on);
    rig.file.value = rigEnvelope(on);
    sim..hashKeyExists = true..egressState = 'ON'..egressGeneration = 30
      ..egressVersion = version..egressOwnerGeneration = sim.ownerGeneration
      ..egressOwnerEpoch = sim.ownerEpoch;
    sim.pending = {'operationId': kSimOperationId, 'transitionGeneration': 30,
        'reservedVersion': version, 'ownerGeneration': sim.ownerGeneration, 'ownerEpoch': sim.ownerEpoch};
    return (proof: await rig.gate.provePendingEnableCommit(current, pending), rig: rig, sim: sim);
  }

  test('exact durable resume rebinds a restarted process epoch before local consent', () async {
    await repo.reserveConsentVersion(capability, verifiedFrontier: 2, operationId: 'op-a');
    final restarted = ConsentCapability(uid: capability.uid, epoch: capability.epoch + 100,
        database: capability.database, isCurrent: () => capability.isCurrent);
    final evidence = await resumeProof(restarted);
    final saved = await repo.saveReservedConsentChoice(restarted,
        const ConsentChoices(cloud: ConsentState.accepted),
        version: 3, operationId: 'op-a', proof: evidence.proof);
    expect(saved.cloudConsentVersion, 3);
    expect(await marks(), (watermark: 3, reserved: 0));
  });

  test('nested save receives no reservation and invalidates the outer reservation without hanging', () async {
    final nested = _NestedRepository(f.host.current!.database);
    await nested.reserveConsentVersion(capability, verifiedFrontier: 2, operationId: 'op-a');
    await expectLater(nested.saveReservedConsentChoice(capability,
        const ConsentChoices(cloud: ConsentState.accepted), version: 3, operationId: 'op-a'),
        throwsA(isA<StaleAdmissionException>()));
    expect((await repo.getSettings()).cloudConsentState, ConsentState.declined);
    expect((await repo.getSettings()).consentVersion, 4);
    expect(await marks(), (watermark: 4, reserved: 0));
  });

  for (final mismatch in ['operation', 'version', 'owner', 'epochWithoutProof', 'watermark', 'lostPending', 'staleCapability']) {
    test('restart proof cannot bypass $mismatch consistency', () async {
      await repo.reserveConsentVersion(capability, verifiedFrontier: 2, operationId: 'op-a');
      var live = true;
      final restarted = ConsentCapability(uid: capability.uid, epoch: capability.epoch + 100,
          database: capability.database, isCurrent: () => live && capability.isCurrent);
      final evidence = await resumeProof(restarted);
      switch (mismatch) {
        case 'operation': await capability.database!.customStatement("UPDATE consent_version_watermark SET reserved_op = 'different'");
        case 'version': await capability.database!.customStatement('UPDATE consent_version_watermark SET reserved = 4');
        case 'owner': await capability.database!.customStatement("UPDATE consent_version_watermark SET reserved_uid = 'other'");
        case 'watermark': await capability.database!.customStatement('UPDATE consent_version_watermark SET watermark = 9');
        case 'lostPending': evidence.rig.pendingFile.value = null;
        case 'staleCapability': live = false;
      }
      await expectLater(repo.saveReservedConsentChoice(restarted,
          const ConsentChoices(cloud: ConsentState.accepted), version: 3, operationId: 'op-a',
          proof: mismatch == 'epochWithoutProof' ? null : evidence.proof),
          throwsA(isA<StaleAdmissionException>()));
      expect((await repo.getSettings()).consentVersion, 0);
      final row = await capability.database!.customSelect('SELECT reserved_epoch FROM consent_version_watermark').getSingle();
      expect(row.read<int>('reserved_epoch'), capability.epoch, reason: 'failed rebinding is atomic');
    });
  }

  test('fabricated pending or changed native lifetime cannot mint resume proof', () async {
    final evidence = await resumeProof(capability);
    final pending = evidence.proof.pending;
    final fabricated = PendingEnableRecord(ownerUid: pending.ownerUid,
        transitionGeneration: pending.transitionGeneration, reservedVersion: pending.reservedVersion,
        localOperationId: 'invented', binding: pending.binding);
    await expectLater(evidence.rig.gate.provePendingEnableCommit(capability, fabricated),
        throwsA(isA<StaleAdmissionException>()));
    evidence.sim.ownerEpoch++;
    await expectLater(evidence.rig.gate.provePendingEnableCommit(capability, pending),
        throwsA(isA<StaleAdmissionException>()));
  });

  test(
      'an ordinary choice without a reservation is the next local version '
      'and raises the watermark', () async {
    final saved = await repo.saveConsentChoice(
        capability, const ConsentChoices(cloud: ConsentState.declined));
    expect(saved.cloudConsentVersion, 1);
    expect((await marks()).watermark, 1);
  });

  test('a lost capability or a different owner reserves nothing', () async {
    f.session.markSessionInvalid();
    await expectLater(
        repo.reserveConsentVersion(capability,
            verifiedFrontier: 9, operationId: 'x'),
        throwsA(isA<StaleAdmissionException>()));
    final other = ConsentCapability(
        uid: 'uid-y',
        epoch: capability.epoch,
        database: capability.database,
        isCurrent: () => true);
    await expectLater(
        repo.reserveConsentVersion(other,
            verifiedFrontier: 9, operationId: 'y'),
        throwsA(isA<StaleAdmissionException>()),
        reason: 'the replica owner is another uid');
    expect(await marks(), (watermark: 0, reserved: 0));
  });
}
