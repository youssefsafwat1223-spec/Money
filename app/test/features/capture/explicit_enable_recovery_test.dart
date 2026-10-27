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

// Astra A3(c) + G2: an explicit management Turn on / Accept chooses its protocol
// from BOTH the stored choice and the live/pending authority. The REAL service,
// gate, session and per-uid Drift replica; only the platform edge (the native
// MethodChannel stand-in, the network client) is scripted. A plain settings save
// is never taken as proof that the native enable completed.

class _Spy extends DriftUserSettingsRepository {
  _Spy(AppDatabase db)
      : database = db,
        super(db);
  final AppDatabase database;
  int saved = 0;
  @override
  void afterConsentChoice(ConsentCapability capability, ConsentChoices choices) {
    saved++;
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('money_companion/native_capture');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late EgressRig rig;
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
        gate: rig.gate,
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

  /// The explicit Accept (both permissions) through the sheet's protocol.
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

  Future<UserSettingsEntity> stored() => settings.getSettings();

  /// The state "stored ON" without any completed native enable behind it.
  Future<UserSettingsEntity> seedStored(ConsentChoices choices) =>
      settings.saveConsentChoice(f.session.captureConsentCapability()!, choices);

  void seedDartOn(int generation, int version) {
    final body = rigEnvelope(rigRecord(EgressState.on, generation, version));
    rig.secure.value = body;
    rig.file.value = body;
  }

  Future<bool> pendingPresent() async =>
      (await rig.gate.readPending()).blocks(kRigOwner);

  setUp(() async {
    previousGate = CloudEgressGate.instance;
    rig = EgressRig();
    CloudEgressGate.instance = rig.gate;
    ConsentAuthority.egressFrozen = false;
    net = _NoNetwork();
    sim = NativeEnableSim();
    NativeCaptureBridge.debugTreatHostAsNative = true;
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
    for (final h in sim.holds.values) {
      if (!h.isCompleted) h.complete();
    }
    await pumpEventQueue(times: 30);
    f.session.configureCaptureOwnerPublish(null);
    f.session.debugResetAdmissionState();
    await f.dispose();
    NativeCaptureBridge.debugTreatHostAsNative = false;
    messenger.setMockMethodCallHandler(channel, null);
    ConsentAuthority.egressFrozen = false;
    CloudEgressGate.instance = previousGate;
  });

  void expectNoEnableWork() {
    expect(sim.of('beginCloudEgressEnable'), isEmpty);
    expect(sim.of('writeCloudEgressEnableOn'), isEmpty);
    expect(sim.of('finishCloudEgressEnable'), isEmpty);
    expect(net.calls, 0, reason: 'no retry / link / sync before completion');
  }

  group('stored ON without a verified live enable: a plain save is refused',
      () {
    test('native unset and no Dart record', () async {
      final seeded = await seedStored(_accept);
      final err = await accept(service());
      expect(err, isNotNull, reason: 'Accept must not look like success');
      expect(settings.saved, 1, reason: 'only the seed: no plain save');
      expect((await stored()).consentVersion, seeded.consentVersion);
      expect(await pendingPresent(), isFalse);
      expectNoEnableWork();
    });

    test('Dart ON but native unset', () async {
      final seeded = await seedStored(_accept);
      seedDartOn(1, seeded.consentVersion);
      final err = await accept(service());
      expect(err, isNotNull);
      expect(settings.saved, 1);
      expect((await stored()).consentVersion, seeded.consentVersion);
      expectNoEnableWork();
    });

    test('Dart ON but native OFF', () async {
      final seeded = await seedStored(_accept);
      seedDartOn(1, seeded.consentVersion);
      sim.egressState = 'OFF';
      sim.egressGeneration = 1;
      sim.egressVersion = seeded.consentVersion;
      final err = await accept(service());
      expect(err, isNotNull);
      expect(settings.saved, 1);
      expectNoEnableWork();
    });

    test('Dart ON but the native state cannot be read', () async {
      final seeded = await seedStored(_accept);
      seedDartOn(1, seeded.consentVersion);
      sim.egressState = 'ON';
      sim.egressGeneration = 1;
      sim.egressVersion = seeded.consentVersion;
      sim.fault('getCloudEgressPending', SimFault.platformError);
      final err = await accept(service());
      expect(err, isNotNull);
      expect(settings.saved, 1);
      expectNoEnableWork();
    });

    test('a corrupt Dart egress layer', () async {
      await seedStored(_accept);
      rig.secure.value = 'not json';
      final err = await accept(service());
      expect(err, isNotNull);
      expect(settings.saved, 1);
      expectNoEnableWork();
    });
  });

  group('verified live ON: completing a partial permission is a plain save',
      () {
    test('Cloud ON (Dart and native agree), AI not yet granted', () async {
      final s = service();
      // A real, completed enable of Cloud only.
      await s.enableCloud(
          write: ConsentWrite(f.session.captureConsentCapability()!, _cloudOnly));
      expect(settings.saved, 1);
      expect(sim.of('beginCloudEgressEnable'), hasLength(1));
      final err = await accept(s);
      expect(err, isNull);
      final row = await stored();
      expect(row.aiConsentGranted, isTrue);
      expect(row.cloudProcessingEnabled, isTrue);
      expect(settings.saved, 2);
      expect(sim.of('beginCloudEgressEnable'), hasLength(1),
          reason: 'no second native enable over a live ON');
      expect(net.calls, 0);
    });
  });

  group('fresh enable', () {
    test('stored OFF goes through the durable native enable once', () async {
      final err = await accept(service());
      expect(err, isNull);
      expect(sim.of('beginCloudEgressEnable'), hasLength(1));
      expect(sim.of('finishCloudEgressEnable'), hasLength(1));
      expect(settings.saved, 1);
      expect((await stored()).cloudProcessingEnabled, isTrue);
      expect(await pendingPresent(), isFalse);
      expect(net.calls, 0);
    });
  });

  group('pending resume', () {
    Future<UserSettingsEntity> leavePendingAfterCommittedChoice() async {
      sim.fault('finishCloudEgressEnable', SimFault.nullReply);
      final err = await accept(service());
      expect(err, isA<CloudEnableIncompleteException>());
      expect(await pendingPresent(), isTrue);
      final row = await stored();
      expect(row.cloudProcessingEnabled, isTrue,
          reason: 'the choice committed; native completion did not');
      return row;
    }

    test('an exact reserved-version resume completes and saves nothing again',
        () async {
      await leavePendingAfterCommittedChoice();
      expect(settings.saved, 1);
      // A fresh process / a later Accept over the same stored ON + pending.
      final err = await accept(service());
      expect(err, isNull);
      expect(settings.saved, 1,
          reason: 'the choice already committed at exactly the reserved '
              'version: not saved again');
      expect(await pendingPresent(), isFalse);
      expect(sim.pending, isNull);
      expect(sim.egressState, 'ON');
      expect(sim.of('beginCloudEgressEnable'), hasLength(2),
          reason: 'resume of the exact operation');
      expect(net.calls, 0);
    });

    test('a mismatched stored version refuses and never re-saves', () async {
      await leavePendingAfterCommittedChoice();
      // The stored row moved on (another explicit change) after the reserve.
      await seedStored(_cloudOnly);
      final savedBefore = settings.saved;
      final versionBefore = (await stored()).consentVersion;
      final err = await accept(service());
      expect(err, isNotNull);
      expect(settings.saved, savedBefore, reason: 'nothing saved');
      expect((await stored()).consentVersion, versionBefore);
      expect(await pendingPresent(), isTrue, reason: 'still denied');
      expect(sim.pending, isNotNull);
      expect(sim.of('finishCloudEgressEnable').length, 1,
          reason: 'only the first, failed completion');
      expect(net.calls, 0);
    });
  });

  group('stale capability', () {
    test('before the first await: nothing happens', () async {
      await seedStored(_accept);
      final scope = work();
      f.session.markSessionInvalid();
      final err = await accept(service(), scope: scope);
      expect(err, isA<StaleAdmissionException>());
      expect(settings.saved, 1);
      expectNoEnableWork();
    });
  });

  group('typed refusals and lifecycle ending at every await', () {
    test('stored ON + native unset reports withdraw-first, not incomplete',
        () async {
      await seedStored(_accept);
      expect(await accept(service()), isA<CloudEnableWithdrawFirstException>());
    });

    test('a mismatched pending reports withdraw-first', () async {
      sim.fault('finishCloudEgressEnable', SimFault.nullReply);
      expect(await accept(service()), isA<CloudEnableIncompleteException>());
      await seedStored(_cloudOnly);
      expect(await accept(service()), isA<CloudEnableWithdrawFirstException>());
    });

    test('the route itself writes and sends nothing', () async {
      final s = service();
      final seeded = await seedStored(_accept);
      final route = await s.explicitEnableRoute(seeded, seeded,
          ownerUid: 'uid-x');
      expect(route, ExplicitEnableRoute.withdrawFirst);
      expect(settings.saved, 1);
      expect(rig.native.writes, 0);
      expect(rig.secure.writes + rig.file.writes, 0);
      expect(rig.pendingSecure.writes + rig.pendingFile.writes, 0);
      expectNoEnableWork();
    });

    test('another owner never routes as the stored one', () async {
      final seeded = await seedStored(_accept);
      expect(
          await service().explicitEnableRoute(seeded, seeded,
              ownerUid: 'uid-other'),
          ExplicitEnableRoute.withdrawFirst);
    });

    test('ending while the live state is being verified: stale, no write',
        () async {
      final s = service();
      await s.enableCloud(
          write: ConsentWrite(f.session.captureConsentCapability()!, _cloudOnly));
      final scope = work();
      sim.onCall = (m) {
        if (m == 'getCloudEgressPending') f.session.markSessionInvalid();
      };
      final err = await accept(s, scope: scope);
      expect(err, isA<StaleAdmissionException>());
      expect(settings.saved, 1, reason: 'the plain save never ran');
      expect(net.calls, 0);
    });

    test('ending during a fresh enable: stale, nothing left ON, no backend',
        () async {
      final scope = work();
      sim.onCall = (m) {
        if (m == 'beginCloudEgressEnable') f.session.markSessionInvalid();
      };
      final err = await accept(service(), scope: scope);
      expect(err, isA<StaleAdmissionException>());
      expect(settings.saved, 0);
      expect(sim.of('writeCloudEgressEnableOn'), isEmpty);
      expect(await rig.gate.permits(owner: kRigOwner), isFalse);
      expect(net.calls, 0);
    });

    test('ending during an exact pending resume: stale, no second save',
        () async {
      sim.fault('finishCloudEgressEnable', SimFault.nullReply);
      expect(await accept(service()), isA<CloudEnableIncompleteException>());
      expect(settings.saved, 1);
      final scope = work();
      var begins = 0;
      sim.onCall = (m) {
        if (m == 'beginCloudEgressEnable' && ++begins == 1) {
          f.session.markSessionInvalid();
        }
      };
      final err = await accept(service(), scope: scope);
      expect(err, isA<StaleAdmissionException>());
      expect(settings.saved, 1);
      expect(await rig.gate.permits(owner: kRigOwner), isFalse);
      expect(net.calls, 0);
    });
  });
}
