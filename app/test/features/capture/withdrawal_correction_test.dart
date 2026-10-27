import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/core/privacy/consent_authority.dart';
import 'package:money_companion/core/session/admission_authority.dart';
import 'package:money_companion/core/session/consent_capability.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/features/capture/services/capture_backend_client.dart';
import 'package:money_companion/features/capture/services/capture_consent_client.dart';
import 'package:money_companion/features/capture/services/capture_device_registration_service.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';
import 'package:money_companion/features/consent/smart_analysis_consent_sheet.dart';

import '../../core/session/f2_fixture.dart';
import '../../harness/native_enable_sim.dart';
import '../../harness/paused_egress_support.dart';

// N-CR-1..3 (Astra R6 section 4): the withdrawal from a pending / uncertain
// enable must (1) verify restriction in every independently admitting runtime
// before it clears evidence or reports completion, (2) never let a stale call
// touch a successor's enable or freeze, and (3) run the established bounded
// drain and one-shot, ack-bound revoke when an effective permission is being
// withdrawn. The REAL service, gate (native layer through the channel, i.e. the
// simulator is the single native truth), session and per-uid Drift replica; only
// the platform edge is scripted.

class _Spy extends DriftUserSettingsRepository {
  _Spy(AppDatabase db, this.trail)
      : database = db,
        super(db);
  final AppDatabase database;
  final List<String> trail;
  int saved = 0;
  @override
  void afterConsentChoice(ConsentCapability capability, ConsentChoices choices) {
    saved++;
    trail.add(choices.cloud == ConsentState.accepted ? 'save_on' : 'local_off');
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

class _SpyConsent extends CaptureConsentClient {
  _SpyConsent(this.trail)
      : super(supabaseUrl: 'https://x.invalid', anonKey: 'anon');
  final List<String> trail;
  final revokes = <({String owner, int generation, int version})>[];
  Object? error;
  Future<void> Function()? hang;
  RevokeResult result = const RevokeResult(ok: true, applied: true);

  @override
  Future<RevokeResult> revoke({
    required String installId,
    required String deviceSecret,
    required String jwt,
    required String ownerUid,
    required int transitionGeneration,
    required int version,
  }) async {
    trail.add('revoke');
    revokes.add(
        (owner: ownerUid, generation: transitionGeneration, version: version));
    await hang?.call();
    if (error != null) throw error!;
    return result;
  }
}

const _cloudOnly =
    ConsentChoices(cloud: ConsentState.accepted, ai: ConsentState.declined);
const _declined =
    ConsentChoices(cloud: ConsentState.declined, ai: ConsentState.declined);
const _accept =
    ConsentChoices(cloud: ConsentState.accepted, ai: ConsentState.accepted);

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
  late _SpyConsent consent;
  late CloudEgressGate previousGate;
  late _Spy settings;
  late List<String> trail;
  late List<String> inflightQueries;
  late List<({bool cloud, String? owner})> configs;
  late Directory markerDir;
  var failConfig = false;
  var owner = 'uid-x';

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

  CaptureDeviceRegistrationService service(
          {Duration timeout = const Duration(seconds: 2),
          bool realConfig = false}) =>
      CaptureDeviceRegistrationService(
        settingsRepository: settings,
        gate: gate,
        client: net,
        consentClient: consent,
        storage: const FlutterSecureStorage(),
        markerDirectory: () async => markerDir,
        revokeTimeout: timeout,
        loadInstallId: () async => 'install-id',
        // [realConfig]: the REAL bridge (through the channel and the simulator),
        // whose default swallows a missing native method.
        writeNativeBackendConfig: realConfig
            ? null
            : ({
                required cloudProcessingEnabled,
                required installId,
                deviceSecret,
                required backendUrl,
                required anonKey,
                required aiConsentGranted,
                ownerUid,
                transitionGeneration,
              }) async {
                if (failConfig) throw StateError('native config down');
                configs.add((cloud: cloudProcessingEnabled, owner: ownerUid));
              },
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
    return ConsentLocalWork(capability,
        <T>(action) => f.session.runConsentLocalOperation(capability, action));
  }

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

  Future<bool> pendingPresent() async =>
      (await gate.readPending()).blocks(owner);

  Future<Object?> enable(
          CaptureDeviceRegistrationService s, ConsentChoices choices) =>
      s
          .enableCloud(
              write:
                  ConsentWrite(f.session.captureConsentCapability()!, choices))
          .then<Object?>((_) => null, onError: (Object e) => e);

  /// Stored ON (Cloud only, committed at the reserved version) with the Dart and
  /// native pending still in place: native completion never confirmed.
  Future<void> leaveCommittedPending() async {
    sim.fault('finishCloudEgressEnable', SimFault.nullReply);
    final err = await enable(service(), _cloudOnly);
    expect(err, isA<CloudEnableIncompleteException>());
    expect(await pendingPresent(), isTrue);
    expect((await stored()).cloudProcessingEnabled, isTrue);
    trail.clear();
  }

  /// Native completed the enable (ON, no barrier); the Dart denial stayed.
  Future<void> nativeCompletedDartPending() async {
    await leaveCommittedPending();
    sim.pending = null;
  }

  /// A server acknowledgment for [owner] (what the post-enable sync leaves).
  Future<void> acknowledge(int version, {String uid = 'uid-x'}) async {
    const storage = FlutterSecureStorage();
    await storage.write(key: 'qirsh_capture_device_secret', value: 'secret');
    await storage.write(
        key: 'qirsh_capture_consent_ack', value: '$uid|1|0|$version');
  }

  void expectNativeRestrictive() {
    expect(sim.egressState, isIn(['DISABLING', 'OFF']),
        reason: 'the native egress record denies');
  }

  setUp(() async {
    previousGate = CloudEgressGate.instance;
    NativeCaptureBridge.debugTreatHostAsNative = true;
    rig = EgressRig();
    inflightQueries = [];
    trail = [];
    configs = [];
    failConfig = false;
    owner = 'uid-x';
    gate = CloudEgressGate(
      store: CloudEgressStore(
          secure: rig.secure,
          file: rig.file,
          native: NativeEgressSlot.platformDefault(),
          pendingSecure: rig.pendingSecure,
          pendingFile: rig.pendingFile),
      activeOwner: () async => owner,
      resolved: true,
      nativeInflight: (o) async {
        inflightQueries.add(o);
        trail.add('inflight');
        return (count: 0, latestDeadline: null);
      },
    );
    CloudEgressGate.instance = gate;
    ConsentAuthority.egressFrozen = false;
    net = _NoNetwork();
    consent = _SpyConsent(trail);
    sim = NativeEnableSim();
    messenger.setMockMethodCallHandler(channel, sim.handle);
    f = await F2Fixture.create();
    markerDir = Directory.systemTemp.createTempSync('n_cr_marker_');
    f.session.configureCaptureOwnerClear(() async {
      sim.ownerAlive = false;
      sim.ownerEpoch++;
      return true;
    });
    f.session.configureCaptureOwnerPublish(publish);
    await signIn('uid-x');
    settings = _Spy(f.host.current!.database, trail);
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
    if (markerDir.existsSync()) markerDir.deleteSync(recursive: true);
  });

  group('N-CR-1 verified restriction in every admitting runtime', () {
    test(
        'baseline: a healthy withdrawal verifies native egress, mirror and '
        'config before it reports completion', () async {
      await leaveCommittedPending();
      expect(await withdraw(service()), isNull);
      expect(sim.egressState, 'OFF');
      expect(sim.mirror?['cloud'], isFalse);
      expect(sim.mirror?['ai'], isFalse);
      expect(configs.any((c) => !c.cloud && c.owner == 'uid-x'), isTrue);
      expect(await pendingPresent(), isFalse);
      expect(sim.pending, isNull);
      expect(await gate.permits(owner: 'uid-x'), isFalse);
    });

    test(
        'native-only write failure with every Dart write succeeding: '
        'incomplete, no evidence cleared, native never proven restricted',
        () async {
      await leaveCommittedPending();
      sim.failEgressWrites = true;
      final err = await withdraw(service());
      expect(err, isA<CloudWithdrawIncompleteException>());
      expect(await pendingPresent(), isTrue,
          reason: 'Dart pending is not cleared over an unrestricted native ON');
      expect(sim.pending, isNotNull);
      expect(sim.of('finishCloudEgressEnable'), hasLength(1),
          reason: 'only the first, failed completion: no abandon was sent');
      expect(sim.egressState, 'ON', reason: 'native still holds ON');
      expect(await gate.permits(owner: 'uid-x'), isFalse,
          reason: 'Dart denies, and the result says it did not finish');
    });

    test('native readback unavailable: incomplete, nothing cleared', () async {
      await leaveCommittedPending();
      sim.failEgressReads = true;
      final err = await withdraw(service());
      expect(err, isA<CloudWithdrawIncompleteException>());
      expect(await pendingPresent(), isTrue);
      expect(sim.pending, isNotNull);
    });

    test('consent-mirror restriction failure: incomplete, nothing cleared',
        () async {
      await leaveCommittedPending();
      sim.failMirror = true;
      final err = await withdraw(service());
      expect(err, isA<CloudWithdrawIncompleteException>());
      expect(await pendingPresent(), isTrue);
      expect(sim.pending, isNotNull);
      expect(sim.of('finishCloudEgressEnable'), hasLength(1));
    });

    test(
        'native backend-config restriction failure: incomplete, nothing '
        'cleared', () async {
      await leaveCommittedPending();
      failConfig = true;
      final err = await withdraw(service());
      expect(err, isA<CloudWithdrawIncompleteException>());
      expect(await pendingPresent(), isTrue);
      expect(sim.pending, isNotNull);
      expect(sim.of('finishCloudEgressEnable'), hasLength(1));
    });

    test(
        'completed-native / Dart-pending with native writes failing: '
        'incomplete, the Dart pending stays', () async {
      await nativeCompletedDartPending();
      sim.failEgressWrites = true;
      final err = await withdraw(service());
      expect(err, isA<CloudWithdrawIncompleteException>());
      expect(await pendingPresent(), isTrue,
          reason: 'native ON was never proven restricted');
      expect(sim.egressState, 'ON');
    });

    test(
        'completed-native / Dart-pending, everything healthy: verified, then '
        'cleared', () async {
      await nativeCompletedDartPending();
      expect(await withdraw(service()), isNull);
      expect(await pendingPresent(), isFalse);
      expect(sim.egressState, 'OFF');
      expect(sim.mirror?['cloud'], isFalse);
    });

    test(
        'both Dart egress layers fail while native takes the record: '
        'incomplete (the Dart runtime is unverified)', () async {
      await leaveCommittedPending();
      rig.secure.failWrites = true;
      rig.file.failWrites = true;
      final err = await withdraw(service());
      expect(err, isA<CloudWithdrawIncompleteException>());
      expect(await pendingPresent(), isTrue);
      expect(sim.pending, isNotNull);
    });

    test(
        'one Dart layer fails while the other and native hold the record: '
        'the existing restrictive merge suffices', () async {
      await leaveCommittedPending();
      rig.secure.failWrites = true;
      expect(await withdraw(service()), isNull);
      expect(await pendingPresent(), isFalse);
      expectNativeRestrictive();
      expect(await gate.permits(owner: 'uid-x'), isFalse);
    });

    test(
        'native cannot take the final OFF but a verified restrictive native '
        'record exists: completion is reported, denial holds', () async {
      await leaveCommittedPending();
      sim.afterApply = (m) {
        if (m == 'abandon') sim.failEgressWrites = true;
      };
      expect(await withdraw(service()), isNull);
      expect(sim.egressState, 'DISABLING');
      expect(await gate.permits(owner: 'uid-x'), isFalse);
    });

    for (final boundary in <String, void Function()>{
      'native egress write': () => sim.failEgressWrites = true,
      'native readback': () => sim.failEgressReads = true,
      'consent mirror': () => sim.failMirror = true,
      'backend config': () => failConfig = true,
    }.entries) {
      test(
          'restart after a ${boundary.key} failure: the next withdrawal '
          'finishes and verifies', () async {
        await leaveCommittedPending();
        boundary.value();
        expect(
            await withdraw(service()), isA<CloudWithdrawIncompleteException>());
        expect(await pendingPresent(), isTrue);
        expect(await gate.permits(owner: 'uid-x'), isFalse);
        sim.failEgressWrites = false;
        sim.failEgressReads = false;
        sim.failMirror = false;
        failConfig = false;
        ConsentAuthority.egressFrozen = false; // a new process
        expect(await withdraw(service()), isNull);
        expect(await pendingPresent(), isFalse);
        expect(sim.pending, isNull);
        expect(sim.egressState, 'OFF');
        expect(sim.mirror?['cloud'], isFalse);
      });
    }
    group('N-R8 truthful outcome at each failure boundary', () {
      String? reasonOf(Object? e) =>
          e is CloudWithdrawIncompleteException ? e.reason : null;

      test('before the local OFF: nothing stored, nothing cleared', () async {
        await leaveCommittedPending();
        sim.failMirror = true;
        final err = await withdraw(service());
        expect(reasonOf(err), 'native_restriction_begin');
        expect((await stored()).cloudProcessingEnabled, isTrue,
            reason: 'the local OFF never ran');
        expect(await pendingPresent(), isTrue);
        expect(sim.pending, isNotNull);
        expect(await gate.permits(owner: 'uid-x'), isFalse);
        expect(ConsentAuthority.egressFrozen, isTrue);
      });

      test('after the local OFF: the native abandon is unconfirmed: the OFF is '
          'stored, the pending evidence is still there, egress stays denied',
          () async {
        await leaveCommittedPending();
        sim.fault('finishCloudEgressEnable', SimFault.nullReply);
        final err = await withdraw(service());
        expect(reasonOf(err), 'native_abandon');
        expect((await stored()).cloudProcessingEnabled, isFalse,
            reason: 'the local OFF already happened');
        expect(await pendingPresent(), isTrue,
            reason: 'the Dart pending was not cleared');
        expect(await gate.permits(owner: 'uid-x'), isFalse);
        expect(ConsentAuthority.egressFrozen, isTrue);
      });

      test('after the evidence was cleared: the FINAL verification fails: the '
          'OFF is stored AND the pending evidence is already cleared, egress '
          'stays denied and the result still says it did not finish',
          () async {
        await leaveCommittedPending();
        sim.afterApply = (m) {
          if (m == 'abandon') sim.failEgressReads = true;
        };
        final err = await withdraw(service());
        expect(err, isA<CloudWithdrawIncompleteException>());
        expect(reasonOf(err), isNot('pending_not_cleared'));
        expect((await stored()).cloudProcessingEnabled, isFalse);
        expect(await pendingPresent(), isFalse,
            reason: 'the evidence WAS cleared before the final read-back');
        expect(sim.pending, isNull);
        expect(await gate.permits(owner: 'uid-x'), isFalse);
        expect(ConsentAuthority.egressFrozen, isTrue);
      });
    });

    group('N-R8 backend-config acknowledgment through the real bridge', () {
      test(
          'the native method is missing while egress inspection and the '
          'mirror still work: NOT an acknowledgment, withdrawal incomplete',
          () async {
        await leaveCommittedPending();
        sim.backendConfigMissing = true;
        final err = await withdraw(service(realConfig: true));
        expect(err, isA<CloudWithdrawIncompleteException>());
        expect(sim.of('setCaptureBackendConfig'), isNotEmpty,
            reason: 'the restriction was attempted');
        expect(sim.mirror?['cloud'], isFalse, reason: 'the mirror worked');
        expectNativeRestrictive();
        expect(await pendingPresent(), isTrue, reason: 'nothing cleared');
        expect(sim.pending, isNotNull);
        expect(sim.of('finishCloudEgressEnable'), hasLength(1),
            reason: 'no abandon was sent');
        expect(await gate.permits(owner: 'uid-x'), isFalse);
        expect(ConsentAuthority.egressFrozen, isTrue);
      });

      test('native refuses the backend config: incomplete, nothing cleared',
          () async {
        await leaveCommittedPending();
        sim.backendConfigRefused = true;
        final err = await withdraw(service(realConfig: true));
        expect(err, isA<CloudWithdrawIncompleteException>());
        expect(await pendingPresent(), isTrue);
        expect(sim.pending, isNotNull);
        expectNativeRestrictive();
      });

      test(
          'ordinary acknowledged success completes and the restrictive config '
          'reached native', () async {
        await leaveCommittedPending();
        expect(await withdraw(service(realConfig: true)), isNull);
        final config = sim.backendConfig;
        expect(config?['cloudProcessingEnabled'], isFalse);
        expect(config?['aiConsentGranted'], isFalse);
        expect(config?['ownerUid'], 'uid-x');
        expect(sim.egressState, 'OFF');
        expect(await pendingPresent(), isFalse);
      });

      test(
          'restart with config/mirror residue while the egress record stays '
          'restrictive: denial holds, the next withdrawal verifies', () async {
        await leaveCommittedPending();
        sim.backendConfigMissing = true;
        sim.mirror = {'uid': 'uid-x', 'cloud': true, 'ai': true};
        expect(await withdraw(service(realConfig: true)),
            isA<CloudWithdrawIncompleteException>());
        expectNativeRestrictive();
        expect(await gate.permits(owner: 'uid-x'), isFalse);
        sim.backendConfigMissing = false;
        ConsentAuthority.egressFrozen = false; // a new process
        expect(await gate.permits(owner: 'uid-x'), isFalse,
            reason: 'the restrictive egress record, not the residue, decides');
        expect(await withdraw(service(realConfig: true)), isNull);
        expect(sim.backendConfig?['cloudProcessingEnabled'], isFalse);
        expect(sim.mirror?['cloud'], isFalse);
        expect(sim.egressState, 'OFF');
        expect(await pendingPresent(), isFalse);
      });

      test(
          'receipt wording: a completed mirror/config call is an execution '
          'acknowledgment, not crash-durability proof', () {
        final source = File(
                'lib/features/capture/services/capture_device_registration_service.dart')
            .readAsStringSync();
        expect(source.contains('a completed call is the receipt'), isFalse);
        expect(source.contains('execution acknowledgment'), isTrue);
        expect(source.contains('not crash-durability proof'), isTrue);
      });
    });
  });

  group('N-CR-2 stale withdrawal and successor ownership', () {
    test(
        'same UID: an obsolete capability neither invalidates a paused '
        'successor enable nor releases anything of it', () async {
      final old = work();
      f.session.markSessionInvalid();
      await signIn('uid-x');
      settings = _Spy(f.host.current!.database, trail);
      final s = service();
      final hold = sim.hold('beginCloudEgressEnable');
      final enabling = enable(s, _cloudOnly);
      await sim.reached['beginCloudEgressEnable']!.future;

      final stale = await withdraw(s, scope: old);
      expect(stale, isA<StaleAdmissionException>());
      expect(settings.saved, 0, reason: 'the obsolete call saved nothing');

      hold.complete();
      expect(await enabling, isNull,
          reason: 'the successor enable keeps its authority');
      expect(sim.egressState, 'ON');
      expect((await stored()).cloudProcessingEnabled, isTrue);
      expect(await pendingPresent(), isFalse);
    });

    test(
        'different UID: an obsolete capability of another account does not '
        'touch the successor enable either', () async {
      final old = work(); // uid-x
      f.session.markSessionInvalid();
      sim = NativeEnableSim(uid: 'uid-y');
      messenger.setMockMethodCallHandler(channel, sim.handle);
      owner = 'uid-y';
      await signIn('uid-y');
      settings = _Spy(f.host.current!.database, trail);
      final s = service();
      final hold = sim.hold('beginCloudEgressEnable');
      final enabling = enable(s, _cloudOnly);
      await sim.reached['beginCloudEgressEnable']!.future;

      expect(await withdraw(s, scope: old), isA<StaleAdmissionException>());

      hold.complete();
      expect(await enabling, isNull);
      expect(sim.egressState, 'ON');
      expect((await stored()).cloudProcessingEnabled, isTrue);
    });

    test(
        'an obsolete capability changes nothing while a successor freeze is '
        'held: the global freeze is not released', () async {
      await leaveCommittedPending();
      final old = work();
      f.session.markSessionInvalid();
      await signIn('uid-x');
      settings = _Spy(f.host.current!.database, trail);
      ConsentAuthority.egressFrozen = true; // the successor's freeze
      expect(await withdraw(service(), scope: old),
          isA<StaleAdmissionException>());
      expect(ConsentAuthority.egressFrozen, isTrue);
      expect(await pendingPresent(), isTrue);
    });

    test(
        'the lifecycle is replaced while the final durable OFF is being '
        'written: stale result, the successor\'s freeze is not released',
        () async {
      await leaveCommittedPending();
      late Completer<void> hold;
      sim.afterApply = (m) {
        if (m == 'abandon') hold = rig.secure.pauseAfterNextWrite();
      };
      final withdrawing = withdraw(service());
      while (rig.secure.reached == null || !rig.secure.reached!.isCompleted) {
        await pumpEventQueue();
      }
      f.session.markSessionInvalid();
      await signIn('uid-x');
      ConsentAuthority.egressFrozen = true; // a successor's freeze
      hold.complete();
      final err = await withdrawing;
      expect(err, isA<StaleAdmissionException>(),
          reason: 'a completion after the lifecycle ended is not success');
      expect(ConsentAuthority.egressFrozen, isTrue,
          reason: 'the stale completion must not release the successor freeze');
    });
  });

  group('N-R8 replacement at each persistence boundary: stored records', () {
    for (final successorUid in ['uid-x', 'uid-y']) {
      for (final boundary in ['secure', 'file']) {
        test('${successorUid == 'uid-x' ? 'same' : 'different'} UID successor '
            'after the $boundary egress write: stale result, the stored '
            'records stay restrictive at the withdrawal\'s own generation and '
            'the successor freeze is kept', () async {
          await leaveCommittedPending();
          final slot = boundary == 'secure' ? rig.secure : rig.file;
          late Completer<void> hold;
          sim.afterApply = (m) {
            if (m == 'abandon') hold = slot.pauseAfterNextWrite();
          };
          final withdrawing = withdraw(service());
          while (slot.reached == null || !slot.reached!.isCompleted) {
            await pumpEventQueue();
          }
          f.session.markSessionInvalid();
          if (successorUid != 'uid-x') {
            sim = NativeEnableSim(uid: successorUid);
            messenger.setMockMethodCallHandler(channel, sim.handle);
            owner = successorUid;
          }
          await signIn(successorUid);
          ConsentAuthority.egressFrozen = true; // the successor's freeze
          hold.complete();
          final err = await withdrawing;
          expect(err, isA<StaleAdmissionException>());
          expect(ConsentAuthority.egressFrozen, isTrue);
          final xs = (await gate.store.readOwnerLayers('uid-x')).records;
          expect(xs, isNotEmpty);
          expect(xs.every((r) => r.restrictive), isTrue,
              reason: 'no ON of the withdrawn owner is stored');
          if (successorUid == 'uid-y') {
            // (The native simulator is owner-agnostic, so only the Dart layers
            // can show whether the successor owner was touched.)
            expect(rig.secure.value ?? '', isNot(contains('uid-y')));
            expect(rig.file.value ?? '', isNot(contains('uid-y')));
          }
          // The exception is not proof that nothing was written: a restrictive
          // record of the OLD generation did land.
          expect(xs.any((r) => r.state == EgressState.off), isTrue);
        });
      }
    }

    test('Q9 successor initialization (same UID) reconciles what the stale '
        'withdrawal left, with the freeze kept until then', () async {
      await leaveCommittedPending();
      late Completer<void> hold;
      sim.afterApply = (m) {
        if (m == 'abandon') hold = rig.secure.pauseAfterNextWrite();
      };
      final withdrawing = withdraw(service());
      while (rig.secure.reached == null || !rig.secure.reached!.isCompleted) {
        await pumpEventQueue();
      }
      f.session.markSessionInvalid();
      await signIn('uid-x');
      settings = _Spy(f.host.current!.database, trail);
      ConsentAuthority.egressFrozen = true;
      hold.complete();
      expect(await withdrawing, isA<StaleAdmissionException>());
      expect(ConsentAuthority.egressFrozen, isTrue,
          reason: 'stale finalization never releases the process freeze');
      // No timeout thaw: nothing unfreezes it by itself.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(ConsentAuthority.egressFrozen, isTrue);
      // The successor's initialization is responsible for reconciliation.
      await service().resolvePendingDisable();
      expect(await gate.permits(owner: 'uid-x'), isFalse,
          reason: 'cloud remains OFF-denied until an explicit enable');
    });

    test('Q9 successor initialization (different UID) leaves the old owner '
        'denied and does not adopt its records', () async {
      await leaveCommittedPending();
      late Completer<void> hold;
      sim.afterApply = (m) {
        if (m == 'abandon') hold = rig.secure.pauseAfterNextWrite();
      };
      final withdrawing = withdraw(service());
      while (rig.secure.reached == null || !rig.secure.reached!.isCompleted) {
        await pumpEventQueue();
      }
      f.session.markSessionInvalid();
      sim = NativeEnableSim(uid: 'uid-y');
      messenger.setMockMethodCallHandler(channel, sim.handle);
      owner = 'uid-y';
      await signIn('uid-y');
      settings = _Spy(f.host.current!.database, trail);
      ConsentAuthority.egressFrozen = true;
      hold.complete();
      expect(await withdrawing, isA<StaleAdmissionException>());
      expect(ConsentAuthority.egressFrozen, isTrue);
      await service().resolvePendingDisable();
      expect(await gate.permits(owner: 'uid-x'), isFalse);
      expect(await gate.permits(owner: 'uid-y'), isFalse,
          reason: 'no ON exists for the successor without an explicit enable');
    });
  });

  group('N-CR-3 drain and one-shot revoke when a permission is effective', () {
    test(
        'pending classified, then the enable finishes and the server '
        'acknowledges before the withdrawal proceeds: the established drain '
        'and ONE revoke run, local OFF is committed', () async {
      await leaveCommittedPending();
      final version = (await stored()).consentVersion;
      // The enable finished meanwhile: native completed, Dart cleared, synced.
      sim.pending = null;
      final rec = (await gate.readPending()).agreed('uid-x')!;
      expect((await gate.clearPendingEnable(rec)).all, isTrue);
      await acknowledge(version);
      trail.clear();

      expect(await withdraw(service()), isNull);
      expect(consent.revokes, hasLength(1));
      expect(consent.revokes.single.owner, 'uid-x');
      expect(trail.indexOf('inflight'), lessThan(trail.indexOf('revoke')),
          reason: 'the bounded drain precedes the revoke');
      expect(trail.indexOf('revoke'), lessThan(trail.indexOf('local_off')),
          reason:
              'the revoke is the last control-plane action of the ON state');
      expect((await stored()).cloudProcessingEnabled, isFalse);
      final outcome = await service().serverRevocation();
      expect(outcome?.status, ServerRevocation.confirmed);
      expect(
          const FlutterSecureStorage().read(key: 'qirsh_capture_consent_ack'),
          completion(isNull));
    });

    test(
        'a pending operation over existing acknowledged server consent: one '
        'revoke', () async {
      await leaveCommittedPending();
      await acknowledge((await stored()).consentVersion);
      expect(await withdraw(service()), isNull);
      expect(consent.revokes, hasLength(1));
      expect(await pendingPresent(), isFalse);
      expect(sim.pending, isNull);
    });

    test(
        'a first enable that never acknowledged: nothing is revoked or '
        'fabricated, and the outcome says not attempted', () async {
      await leaveCommittedPending();
      expect(await withdraw(service()), isNull);
      expect(consent.revokes, isEmpty);
      expect(net.calls, 0);
      final outcome = await service().serverRevocation();
      expect(outcome?.status, ServerRevocation.notAttempted);
      expect((await stored()).cloudProcessingEnabled, isFalse);
    });

    test(
        'the in-flight native requests are drained before the OFF is '
        'committed', () async {
      await leaveCommittedPending();
      expect(await withdraw(service()), isNull);
      expect(inflightQueries, contains('uid-x'));
      expect(trail.indexOf('inflight'), lessThan(trail.indexOf('local_off')));
    });

    test(
        'a failed revoke does not block local OFF; the outcome is '
        'unconfirmed and nothing retries', () async {
      await leaveCommittedPending();
      await acknowledge((await stored()).consentVersion);
      consent.error = const CaptureBackendException('offline');
      expect(await withdraw(service()), isNull);
      expect((await stored()).cloudProcessingEnabled, isFalse);
      expect((await service().serverRevocation())?.status,
          ServerRevocation.unconfirmed);
      ConsentAuthority.egressFrozen = false;
      expect(await withdraw(service()), isNull);
      expect(consent.revokes, hasLength(1),
          reason: 'one attempt, success or not');
    });

    test('a revoke that times out does not block local OFF', () async {
      await leaveCommittedPending();
      await acknowledge((await stored()).consentVersion);
      consent.hang = () => Completer<void>().future;
      expect(await withdraw(service(timeout: const Duration(milliseconds: 50))),
          isNull);
      expect((await stored()).cloudProcessingEnabled, isFalse);
      expect((await service().serverRevocation())?.status,
          ServerRevocation.unconfirmed);
      expect(consent.revokes, hasLength(1));
    });

    test('no revoke is sent while the restriction is unverified', () async {
      await leaveCommittedPending();
      await acknowledge((await stored()).consentVersion);
      sim.failEgressWrites = true;
      expect(
          await withdraw(service()), isA<CloudWithdrawIncompleteException>());
      expect(consent.revokes, isEmpty);
    });

    test('N-R8 wording: missing qualifying revoke inputs are "revoke not '
        'attempted", never "nothing to revoke", and no claim that every later '
        'failure leaves all evidence uncleared', () {
      final source = File(
              'lib/features/capture/services/capture_device_registration_service.dart')
          .readAsStringSync();
      expect(source.contains('nothing to revoke'), isFalse);
      expect(source.contains('revoke not attempted'), isTrue);
      expect(source.contains('with nothing cleared'), isFalse);
      expect(source.contains('FINAL read-back'), isTrue);
    });

    test('N-R8 stored OFF with a leftover acknowledgment: zero revoke, the '
        'outcome is not attempted (no confirmed server OFF), no startup retry',
        () async {
      await leaveCommittedPending();
      await acknowledge((await stored()).consentVersion);
      // The person's stored choice is already OFF (the row), the ack is left.
      await settings.saveConsentChoice(
          f.session.captureConsentCapability()!, _declined);
      expect((await stored()).cloudProcessingEnabled, isFalse);
      trail.clear();
      final s = service();
      expect(await withdraw(s), isNull);
      expect(consent.revokes, isEmpty, reason: 'no qualifying stored ON');
      expect(trail, isNot(contains('revoke')));
      final outcome = await s.serverRevocation();
      expect(outcome?.status, ServerRevocation.notAttempted);
      expect(outcome?.status, isNot(ServerRevocation.confirmed));
      // The leftover acknowledgment is not consumed, relinked or retried.
      expect(
          await const FlutterSecureStorage()
              .read(key: 'qirsh_capture_consent_ack'),
          isNotNull);
      await s.resolvePendingDisable();
      expect(consent.revokes, isEmpty, reason: 'no startup retry');
    });

    test(
        'the "has not linked or pushed anything" claim is gone from the '
        'withdrawal contract', () {
      final source = File(
              'lib/features/capture/services/capture_device_registration_service.dart')
          .readAsStringSync();
      expect(source.contains('has not linked'), isFalse);
      expect(source.contains('No server revoke is sent'), isFalse);
    });
  });

  group('the prior behaviour that must survive', () {
    test('a withdrawal then a fresh enable still completes', () async {
      await leaveCommittedPending();
      final s = service();
      expect(await withdraw(s), isNull);
      expect(await enable(s, _accept), isNull);
      expect(sim.egressState, 'ON');
      expect(await pendingPresent(), isFalse);
    });
  });
}
