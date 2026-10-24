import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/core/privacy/consent_authority.dart';
import 'package:money_companion/core/session/admission_authority.dart';
import 'package:money_companion/core/session/consent_capability.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/features/capture/services/capture_backend_client.dart';
import 'package:money_companion/features/capture/services/capture_device_registration_service.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';
import 'package:money_companion/features/consent/smart_analysis_consent_sheet.dart';

import '../../core/session/f2_fixture.dart';
import '../../harness/native_enable_sim.dart';
import '../../harness/paused_egress_support.dart';

// R17 / R18 (Astra R45): resumable versus unresolved pending enables, the
// truthful result of an explicit choice, and the verified withdrawal from a
// pending/uncertain enable. The REAL service, gate (its native layer reached
// through the channel, i.e. the simulator is the single native truth), session
// and per-uid Drift replica; only the platform edge is scripted.

class _Spy extends DriftUserSettingsRepository {
  _Spy(AppDatabase db)
      : database = db,
        super(db);
  final AppDatabase database;
  int saved = 0;
  bool failSaves = false;
  @override
  Future<UserSettingsEntity> saveConsentChoice(
      ConsentCapability capability, ConsentChoices choices) async {
    if (failSaves) throw StateError('settings write failed');
    final result = await super.saveConsentChoice(capability, choices);
    saved++;
    return result;
  }
}

class _NoNetwork implements CaptureBackendClient {
  int calls = 0;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls++;
    throw StateError('unexpected network operation');
  }
}

const _accept =
    ConsentChoices(cloud: ConsentState.accepted, ai: ConsentState.accepted);
const _cloudOnly =
    ConsentChoices(cloud: ConsentState.accepted, ai: ConsentState.declined);
const _declined =
    ConsentChoices(cloud: ConsentState.declined, ai: ConsentState.declined);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('money_companion/native_capture');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late EgressRig rig;
  late CloudEgressGate gate;
  late F2Fixture f;
  late NativeEnableSim sim;
  late _NoNetwork net;
  late CloudEgressGate previousGate;
  late _Spy settings;

  Future<RestrictiveCaptureOwnerReceipt?> publish(
      String uid, AdmissionAuthority authority) async {
    final epoch = await NativeCaptureBridge.captureOwnerEpoch();
    return NativeCaptureBridge.publishRestrictiveCaptureOwner(
        uid: uid, version: 0, expectedEpoch: epoch);
  }

  Future<void> signIn(String uid) async {
    final sdk = await F2Fixture.liveClient(uid);
    f.session.configureConsentSdkClient(() => sdk);
    await f.signIn(uid);
  }

  CaptureDeviceRegistrationService service() => CaptureDeviceRegistrationService(
        settingsRepository: settings,
        gate: gate,
        client: net,
        isIos: () => true,
        isBackendConfigured: () => true,
        readSession: () => f.host.activeUid == null
            ? null
            : (uid: f.host.activeUid!, jwt: 'jwt'),
        captureWorkAuthority: f.session.captureLocalWorkAuthority,
        isCurrentScope: () =>
            identical(f.host.current?.database, settings.database),
        readReplicaOwnerUid: f.session.readLocalDataOwnerUid,
      );

  ConsentLocalWork work() {
    final capability = f.session.captureConsentCapability()!;
    return ConsentLocalWork(
        capability,
        <T>(action) =>
            f.session.runConsentLocalOperation(capability, action));
  }

  Future<Object?> accept(CaptureDeviceRegistrationService s,
          {ConsentLocalWork? scope}) =>
      applyConsentChoice(
        scope: scope ?? work(),
        repository: settings,
        writer: settings,
        service: s,
        cloud: true,
        ai: true,
      ).then<Object?>((_) => null, onError: (Object e) => e);

  Future<Object?> withdraw(CaptureDeviceRegistrationService s,
      {ConsentLocalWork? scope}) {
    final w = scope ?? work();
    return s
        .withdrawPendingEnable(
            capability: w.capability,
            commitLocalOff: () => w.run(() async {
                  await settings.saveConsentChoice(w.capability, _declined);
                }))
        .then<Object?>((_) => null, onError: (Object e) => e);
  }

  Future<UserSettingsEntity> stored() => settings.getSettings();

  Future<PendingEnableState> state(CaptureDeviceRegistrationService s,
          {String owner = 'uid-x'}) async =>
      s.pendingEnableState(await stored(), ownerUid: owner);

  Future<bool> pendingPresent() async =>
      (await gate.readPending()).blocks(kRigOwner);

  /// Stored ON (Cloud only, committed at the reserved version) with the Dart and
  /// native pending still in place: native completion never confirmed.
  Future<void> leaveCommittedPending() async {
    sim.fault('finishCloudEgressEnable', SimFault.nullReply);
    final err = await service()
        .enableCloud(
            write: ConsentWrite(f.session.captureConsentCapability()!, _cloudOnly))
        .then<Object?>((_) => null, onError: (Object e) => e);
    expect(err, isA<CloudEnableIncompleteException>());
    expect(await pendingPresent(), isTrue);
    expect((await stored()).cloudProcessingEnabled, isTrue);
  }

  /// Stored OFF with only the Dart denial (native `begin` never answered).
  Future<void> leaveDeniedPending() async {
    sim.fault('beginCloudEgressEnable', SimFault.nullReply);
    final err = await service()
        .enableCloud(
            write: ConsentWrite(f.session.captureConsentCapability()!, _cloudOnly))
        .then<Object?>((_) => null, onError: (Object e) => e);
    expect(err, isA<CloudEnableIncompleteException>());
    expect(await pendingPresent(), isTrue);
    expect((await stored()).cloudProcessingEnabled, isFalse);
  }

  void expectDenied() {
    expect(sim.egressState, isNot('ON'));
  }

  setUp(() async {
    previousGate = CloudEgressGate.instance;
    NativeCaptureBridge.debugTreatHostAsNative = true;
    rig = EgressRig();
    // Production shape: the native egress layer is reached through the channel.
    gate = CloudEgressGate(
      store: CloudEgressStore(
          secure: rig.secure,
          file: rig.file,
          native: NativeEgressSlot.platformDefault(),
          pendingSecure: rig.pendingSecure,
          pendingFile: rig.pendingFile),
      activeOwner: () async => kRigOwner,
      resolved: true,
      nativeInflight: (_) async => (count: 0, latestDeadline: null),
    );
    CloudEgressGate.instance = gate;
    ConsentAuthority.egressFrozen = false;
    net = _NoNetwork();
    sim = NativeEnableSim();
    messenger.setMockMethodCallHandler(channel, sim.handle);
    f = await F2Fixture.create();
    f.session.configureCaptureOwnerClear(() async {
      sim.ownerAlive = false;
      sim.ownerEpoch++;
      return true;
    });
    f.session.configureCaptureOwnerPublish(publish);
    await signIn('uid-x');
    settings = _Spy(f.host.current!.database);
  });

  tearDown(() async {
    sim.releaseAll();
    await pumpEventQueue(times: 30);
    f.session.configureCaptureOwnerPublish(null);
    f.session.debugResetAdmissionState();
    await f.dispose();
    NativeCaptureBridge.debugTreatHostAsNative = false;
    messenger.setMockMethodCallHandler(channel, null);
    ConsentAuthority.egressFrozen = false;
    CloudEgressGate.instance = previousGate;
  });

  group('R17 resumable versus unresolved', () {
    test('nothing pending', () async {
      expect(await state(service()), PendingEnableState.none);
    });

    test('a committed pending at exactly the stored version is resumable',
        () async {
      await leaveCommittedPending();
      expect(await state(service()), PendingEnableState.resumable);
    });

    test('a denied-stage pending reserved at stored version + 1 is resumable',
        () async {
      await leaveDeniedPending();
      expect(await state(service()), PendingEnableState.resumable);
    });

    test('a stored version that moved on is unresolved, and so is the route',
        () async {
      await leaveCommittedPending();
      await settings.saveConsentChoice(
          f.session.captureConsentCapability()!, _accept);
      final s = service();
      expect(await state(s), PendingEnableState.unresolved);
      final row = await stored();
      expect(
          await s.explicitEnableRoute(row, row, ownerUid: 'uid-x'),
          ExplicitEnableRoute.withdrawFirst);
    });

    test('stored OFF with a pending of another reserved version: unresolved, '
        'the fresh-enable route refuses', () async {
      await leaveDeniedPending();
      // The stored row moved: reserved no longer equals stored version + 1.
      await settings.saveConsentChoice(
          f.session.captureConsentCapability()!, _declined);
      final s = service();
      expect(await state(s), PendingEnableState.unresolved);
      final row = await stored();
      expect(
          await s.explicitEnableRoute(
              row, _cloudOnly.applyTo(row),
              ownerUid: 'uid-x'),
          ExplicitEnableRoute.withdrawFirst);
      expect(sim.of('beginCloudEgressEnable'), hasLength(1));
    });

    test('Dart layers that disagree are unresolved', () async {
      await leaveCommittedPending();
      final rec = (await gate.readPending()).agreed('uid-x')!;
      await rig.pendingFile.write(
          '{"v":1,"records":{"uid-x":{"owner_uid":"uid-x","transition_generation":${rec.transitionGeneration + 5},"reserved_version":${rec.reservedVersion},"operation":"other","native":null}}}');
      expect(await state(service()), PendingEnableState.unresolved);
    });

    test('a corrupt Dart layer is unresolved', () async {
      await leaveCommittedPending();
      rig.pendingSecure.value = 'not json';
      expect(await state(service()), PendingEnableState.unresolved);
    });

    test('native layers that disagree / hold one entry / are unreadable are '
        'unresolved', () async {
      await leaveCommittedPending();
      final s = service();
      sim.pendingLayersConflict = true;
      expect(await state(s), PendingEnableState.unresolved);
      sim.pendingLayersConflict = false;
      sim.pendingOnlyInLayer = 'file';
      expect(await state(s), PendingEnableState.unresolved);
      sim.pendingOnlyInLayer = null;
      sim.fault('getCloudEgressPending', SimFault.uncertain);
      expect(await state(s), PendingEnableState.unresolved);
      sim.fault('getCloudEgressPending', SimFault.platformError);
      expect(await state(s), PendingEnableState.unresolved);
      expect(await state(s), PendingEnableState.resumable,
          reason: 'back to a consistent native pending');
    });

    test('a bound Dart pending that native no longer holds is unresolved',
        () async {
      await leaveCommittedPending();
      sim.pending = null;
      expect(await state(service()), PendingEnableState.unresolved);
    });

    test('a successor owner lifecycle makes the operation unresolved',
        () async {
      await leaveCommittedPending();
      sim.ownerEpoch++;
      expect(await state(service()), PendingEnableState.unresolved);
    });

    test('another owner is never resumable through this one', () async {
      await leaveCommittedPending();
      expect(await state(service(), owner: 'uid-other'),
          PendingEnableState.unresolved);
    });

    test('an enable still running in this process is unresolved', () async {
      final hold = sim.hold('beginCloudEgressEnable');
      final s = service();
      final running = s
          .enableCloud(
              write: ConsentWrite(
                  f.session.captureConsentCapability()!, _cloudOnly))
          .then<Object?>((_) => null, onError: (Object e) => e);
      await sim.reached['beginCloudEgressEnable']!.future;
      expect(await state(s), PendingEnableState.unresolved);
      hold.complete();
      expect(await running, isNull);
    });
  });

  group('R17 the result is the persisted row', () {
    test('Cloud-only pending resumed from a both-permission Accept: the '
        'widening is NOT reported as saved', () async {
      await leaveCommittedPending();
      expect(settings.saved, 1);
      final s = service();
      final err = await accept(s);
      expect(err, isA<ConsentChoiceNotPersistedException>());
      final persisted = (err as ConsentChoiceNotPersistedException).persisted;
      expect(persisted.cloudProcessingEnabled, isTrue);
      expect(persisted.aiConsentGranted, isFalse);
      final row = await stored();
      expect(row.aiConsentGranted, isFalse, reason: 'AI was never saved');
      expect(settings.saved, 1, reason: 'the resume skipped saving');
      expect(await pendingPresent(), isFalse, reason: 'the old op completed');
      expect(sim.egressState, 'ON');
      expect(net.calls, 0);
      // The widening needs its own explicit, separately versioned write.
      final again = await accept(s);
      expect(again, isNull);
      expect((await stored()).aiConsentGranted, isTrue);
      expect(settings.saved, 2);
      expect(sim.of('beginCloudEgressEnable'), hasLength(2));
    });

    test('an exact resume of the same choice saves nothing and reports the '
        'stored row', () async {
      sim.fault('finishCloudEgressEnable', SimFault.nullReply);
      final first = await accept(service());
      expect(first, isA<CloudEnableIncompleteException>());
      expect(settings.saved, 1);
      final again = await accept(service());
      expect(again, isNull);
      expect(settings.saved, 1);
      final row = await stored();
      expect(row.cloudProcessingEnabled && row.aiConsentGranted, isTrue);
    });

    test('a denied-stage pending resumed by a both-permission Accept saves '
        'that choice once', () async {
      await leaveDeniedPending();
      final err = await accept(service());
      expect(err, isNull);
      final row = await stored();
      expect(row.cloudProcessingEnabled && row.aiConsentGranted, isTrue);
      expect(settings.saved, 1);
      expect(await pendingPresent(), isFalse);
    });

    test('mismatched versions refuse with nothing saved', () async {
      await leaveCommittedPending();
      await settings.saveConsentChoice(
          f.session.captureConsentCapability()!, _accept);
      final before = settings.saved;
      final err = await accept(service());
      expect(err, isA<CloudEnableWithdrawFirstException>());
      expect(settings.saved, before);
      expect(await pendingPresent(), isTrue);
      expect(sim.of('beginCloudEgressEnable'), hasLength(1));
      expect(net.calls, 0);
    });

    test('conflicting native layers refuse; nothing saved or sent', () async {
      await leaveCommittedPending();
      sim.pendingLayersConflict = true;
      final err = await accept(service());
      expect(err, isA<CloudEnableWithdrawFirstException>());
      expect(settings.saved, 1);
      expect(sim.of('beginCloudEgressEnable'), hasLength(1));
      expect(net.calls, 0);
    });
  });

  group('R18 verified withdrawal', () {
    test('a committed pending: restrictive first, then the exact evidence is '
        'cleared, and both choices end OFF', () async {
      await leaveCommittedPending();
      final trail = <String>[];
      sim.onCall = (m) {
        if (m == 'finishCloudEgressEnable') {
          trail.add('abandon@saved=${settings.saved}@egress=${sim.egressState}');
        }
      };
      final err = await withdraw(service());
      expect(err, isNull);
      final row = await stored();
      expect(row.cloudProcessingEnabled, isFalse);
      expect(row.aiConsentGranted, isFalse);
      expect(await pendingPresent(), isFalse);
      expect(sim.pending, isNull);
      expect(sim.egressState, 'OFF');
      expect(await gate.permits(owner: 'uid-x'), isFalse);
      expect(trail, ['abandon@saved=2@egress=DISABLING'],
          reason: 'the local OFF and the restrictive egress record come '
              'before the pending is abandoned');
      expect(net.calls, 0);
    });

    test('a denied-stage pending: only the Dart denial is cleared', () async {
      await leaveDeniedPending();
      final err = await withdraw(service());
      expect(err, isNull);
      expect(await pendingPresent(), isFalse);
      expect(sim.of('finishCloudEgressEnable'), isEmpty,
          reason: 'native never held an operation');
      expect((await stored()).cloudProcessingEnabled, isFalse);
    });

    test('a mismatched stored version still withdraws the exact operation',
        () async {
      await leaveCommittedPending();
      await settings.saveConsentChoice(
          f.session.captureConsentCapability()!, _accept);
      expect(await withdraw(service()), isNull);
      expect(await pendingPresent(), isFalse);
      expect(sim.pending, isNull);
      expectDenied();
    });

    test('after a native completion that Dart never saw: restrictive OFF, no '
        'native abandon', () async {
      await leaveCommittedPending();
      sim.pending = null; // native completed; the Dart denial stayed
      expect(await withdraw(service()), isNull);
      expect(await pendingPresent(), isFalse);
      expect(sim.egressState, 'OFF');
    });

    test('withdrawal, then a fresh enable, completes', () async {
      await leaveCommittedPending();
      final s = service();
      expect(await withdraw(s), isNull);
      expect(await state(s), PendingEnableState.none);
      final err = await accept(s);
      expect(err, isNull);
      final row = await stored();
      expect(row.cloudProcessingEnabled && row.aiConsentGranted, isTrue);
      expect(await pendingPresent(), isFalse);
      expect(sim.egressState, 'ON');
    });

    test('conflicting Dart layers: incomplete, nothing cleared, still denied',
        () async {
      await leaveCommittedPending();
      final rec = (await gate.readPending()).agreed('uid-x')!;
      await rig.pendingFile.write(
          '{"v":1,"records":{"uid-x":{"owner_uid":"uid-x","transition_generation":${rec.transitionGeneration + 9},"reserved_version":${rec.reservedVersion},"operation":"other","native":null}}}');
      final savedBefore = settings.saved;
      final err = await withdraw(service());
      expect(err, isA<CloudWithdrawIncompleteException>());
      expect(settings.saved, savedBefore);
      expect(await pendingPresent(), isTrue);
      expect(sim.pending, isNotNull);
      expect(sim.of('finishCloudEgressEnable').length, 1,
          reason: 'only the first, failed completion');
    });

    test('a corrupt Dart layer: incomplete and denied', () async {
      await leaveCommittedPending();
      rig.pendingSecure.value = 'not json';
      final err = await withdraw(service());
      expect(err, isA<CloudWithdrawIncompleteException>());
      expect(await pendingPresent(), isTrue);
      expect(sim.pending, isNotNull);
    });

    for (final status in [
      SimFault.uncertain,
      SimFault.conflict,
      SimFault.incomplete,
      SimFault.platformError,
      SimFault.nullReply,
    ]) {
      test('native inspection $status: incomplete, nothing cleared', () async {
        await leaveCommittedPending();
        sim.fault('getCloudEgressPending', status);
        final savedBefore = settings.saved;
        final err = await withdraw(service());
        expect(err, isA<CloudWithdrawIncompleteException>());
        expect(settings.saved, savedBefore);
        expect(await pendingPresent(), isTrue);
        expect(sim.pending, isNotNull);
      });
    }

    test('native conflicting / one-layer pending: incomplete', () async {
      await leaveCommittedPending();
      sim.pendingLayersConflict = true;
      expect(await withdraw(service()), isA<CloudWithdrawIncompleteException>());
      sim.pendingLayersConflict = false;
      sim.pendingOnlyInLayer = 'keychain';
      expect(await withdraw(service()), isA<CloudWithdrawIncompleteException>());
      expect(await pendingPresent(), isTrue);
      expect(sim.pending, isNotNull);
    });

    test('native abandon not confirmed: pending stays, a later withdrawal '
        'completes (restart)', () async {
      await leaveCommittedPending();
      sim.fault('finishCloudEgressEnable', SimFault.incomplete);
      final err = await withdraw(service());
      expect(err, isA<CloudWithdrawIncompleteException>());
      expect(await pendingPresent(), isTrue);
      expect(sim.pending, isNotNull);
      expect((await stored()).cloudProcessingEnabled, isFalse);
      expectDenied();
      ConsentAuthority.egressFrozen = false; // a new process
      expect(await withdraw(service()), isNull);
      expect(await pendingPresent(), isFalse);
      expect(sim.pending, isNull);
    });

    test('the local OFF cannot be written: nothing is cleared, still denied',
        () async {
      await leaveCommittedPending();
      settings.failSaves = true;
      final err = await withdraw(service());
      expect(err, isNotNull);
      expect(await pendingPresent(), isTrue);
      expect(sim.pending, isNotNull);
      expect(await gate.permits(owner: 'uid-x'), isFalse);
      settings.failSaves = false;
      ConsentAuthority.egressFrozen = false;
      expect(await withdraw(service()), isNull);
      expect(await pendingPresent(), isFalse);
    });

    test('the Dart pending cannot be cleared: incomplete, a restart finishes',
        () async {
      await leaveCommittedPending();
      rig.pendingSecure.failNextWrite = true;
      final err = await withdraw(service());
      expect(err, isA<CloudWithdrawIncompleteException>());
      expect(await pendingPresent(), isTrue);
      expect(await gate.permits(owner: 'uid-x'), isFalse);
      ConsentAuthority.egressFrozen = false;
      expect(await withdraw(service()), isNull);
      expect(await pendingPresent(), isFalse);
    });

    test('the durable OFF cannot be written after the cleanup: reported, '
        'still denied (DISABLING), a restart finishes', () async {
      await leaveCommittedPending();
      sim.afterApply = (m) {
        if (m == 'abandon') {
          rig.secure.failWrites = true;
          rig.file.failWrites = true;
          sim.failEgressWrites = true;
        }
      };
      final err = await withdraw(service());
      expect(err, isA<CloudWithdrawIncompleteException>());
      expect(await gate.permits(owner: 'uid-x'), isFalse);
      expect(sim.egressState, 'DISABLING');
      sim.afterApply = null;
      rig.secure.failWrites = false;
      rig.file.failWrites = false;
      sim.failEgressWrites = false;
      ConsentAuthority.egressFrozen = false;
      expect(await withdraw(service()), isNull);
      expect(sim.egressState, 'OFF');
    });

    test('finish versus withdrawal: the withdrawal started while the finish '
        'is in flight invalidates it and ends restrictive', () async {
      final s = service();
      final hold = sim.hold('finishCloudEgressEnable');
      final enabling = s
          .enableCloud(
              write: ConsentWrite(
                  f.session.captureConsentCapability()!, _cloudOnly))
          .then<Object?>((_) => null, onError: (Object e) => e);
      await sim.reached['finishCloudEgressEnable']!.future;
      final withdrawing = withdraw(s);
      await pumpEventQueue(times: 10);
      hold.complete();
      final enableResult = await enabling;
      expect(enableResult, isA<StaleAdmissionException>(),
          reason: 'the outgoing enable lost its authority');
      expect(await withdrawing, isNull);
      expect(await pendingPresent(), isFalse);
      expect((await stored()).cloudProcessingEnabled, isFalse);
      expect(sim.egressState, 'OFF');
      expect(await gate.permits(owner: 'uid-x'), isFalse);
      expect(net.calls, 0);
    });

    test('an enable asked while the withdrawal runs: the route refuses, and a '
        'direct enable waits for it and then runs fresh', () async {
      await leaveCommittedPending();
      final s = service();
      final hold = sim.hold('finishCloudEgressEnable');
      final withdrawing = withdraw(s);
      await sim.reached['finishCloudEgressEnable']!.future;
      expect(await accept(s), isA<CloudEnableWithdrawFirstException>(),
          reason: 'a withdrawal is running: no Turn on');
      final enabling = s
          .enableCloud(
              write: ConsentWrite(f.session.captureConsentCapability()!, _accept))
          .then<Object?>((_) => null, onError: (Object e) => e);
      await pumpEventQueue(times: 10);
      expect(sim.of('beginCloudEgressEnable'), hasLength(1),
          reason: 'the new enable has not started');
      hold.complete();
      expect(await withdrawing, isNull);
      expect(await enabling, isNull);
      expect(sim.of('beginCloudEgressEnable'), hasLength(2));
      expect(sim.egressState, 'ON');
      expect(await pendingPresent(), isFalse);
    });

    test('an ended lifecycle changes nothing, even with a new valid '
        'capability', () async {
      await leaveCommittedPending();
      final old = work();
      f.session.markSessionInvalid();
      await signIn('uid-x');
      expect(f.session.captureConsentCapability(), isNotNull);
      final savedBefore = settings.saved;
      final err = await withdraw(service(), scope: old);
      expect(err, isA<StaleAdmissionException>());
      expect(settings.saved, savedBefore);
      expect(await pendingPresent(), isTrue);
      expect(sim.pending, isNotNull);
    });

    test('another owner\'s pending is never touched', () async {
      await leaveCommittedPending();
      const other = PendingEnableRecord(
          ownerUid: 'uid-other',
          transitionGeneration: 4,
          reservedVersion: 9,
          localOperationId: 'op-other');
      expect((await gate.beginPendingEnable(other)).all, isTrue);
      expect(await withdraw(service()), isNull);
      final readout = await gate.readPending();
      expect(readout.agreed('uid-other'), other);
      expect(readout.blocks('uid-x'), isFalse);
    });

    test('the lifecycle ending during the withdrawal: stale, still denied',
        () async {
      await leaveCommittedPending();
      sim.onCall = (m) {
        if (m == 'finishCloudEgressEnable') f.session.markSessionInvalid();
      };
      final err = await withdraw(service());
      expect(err, isA<StaleAdmissionException>());
      expect(await gate.permits(owner: 'uid-x'), isFalse);
    });
  });
}
