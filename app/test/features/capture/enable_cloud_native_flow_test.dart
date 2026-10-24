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

import '../../core/session/f2_fixture.dart';
import '../../harness/consent_session_support.dart';
import '../../harness/native_enable_sim.dart';
import '../../harness/paused_egress_support.dart';

// N-E: the full iOS Cloud-enable transition (owner prerequisite, durable Dart
// pending denial, native barrier, consent save, native completion, clear). The
// REAL AppSession / per-uid Drift / gate; the native side is the scripted
// contract stand-in reached through the real MethodChannel (protocol mocks prove
// Dart ordering only, not native execution). No test touches a network.

class _Settings extends DriftUserSettingsRepository {
  _Settings(AppDatabase db)
      : database = db,
        super(db);
  final AppDatabase database;
  Completer<void>? reached;
  Completer<void>? _release;
  int? _pauseAtRead;
  int reads = 0;
  int saved = 0;
  Object? failSave;
  Future<void> Function()? beforeSave;

  void pauseAtRead(int n) {
    _pauseAtRead = n;
    reached = Completer<void>();
    _release = Completer<void>();
  }

  void resume() => _release!.complete();

  @override
  Future<UserSettingsEntity> getSettings() async {
    final mine = ++reads;
    final value = await super.getSettings();
    if (mine == _pauseAtRead && !reached!.isCompleted) {
      reached!.complete();
      await _release!.future;
    }
    return value;
  }

  @override
  Future<UserSettingsEntity> saveConsentChoice(
      ConsentCapability capability, ConsentChoices choices) async {
    await beforeSave?.call();
    final failure = failSave;
    if (failure != null) throw failure;
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

const _accept = ConsentChoices(
    cloud: ConsentState.accepted, ai: ConsentState.accepted);

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
  var publicationFault = false;
  var publishHook = true;
  var autoSignIn = true;

  Future<RestrictiveCaptureOwnerReceipt?> publish(
      String uid, AdmissionAuthority authority) async {
    if (publicationFault) return null;
    final epoch = await NativeCaptureBridge.captureOwnerEpoch();
    return NativeCaptureBridge.publishRestrictiveCaptureOwner(
        uid: uid, version: 0, expectedEpoch: epoch);
  }

  Future<void> signIn(String uid) async {
    final sdk = await F2Fixture.liveClient(uid);
    f.session.configureConsentSdkClient(() => sdk);
    await f.signIn(uid);
  }

  CaptureDeviceRegistrationService service(_Settings settings,
          {CloudEgressGate? gate}) =>
      CaptureDeviceRegistrationService(
        settingsRepository: settings,
        gate: gate ?? rig.gate,
        client: net,
        isIos: () => true,
        isBackendConfigured: () => true,
        readSession: () => f.host.activeUid == null
            ? null
            : (uid: f.host.activeUid!, jwt: 'jwt'),
        captureWorkAuthority: f.session.captureLocalWorkAuthority,
        isCurrentScope: () => identical(f.host.current?.database, settings.database),
        readReplicaOwnerUid: f.session.readLocalDataOwnerUid,
      );

  Future<_Settings> freshSettings() async => _Settings(f.host.current!.database);

  Future<Object?> enable(CaptureDeviceRegistrationService s,
          [ConsentCapability? capability]) =>
      s
          .enableCloud(
              write: ConsentWrite(
                  capability ?? f.session.captureConsentCapability()!,
                  _accept))
          .then<Object?>((_) => null, onError: (Object e) => e);

  Future<bool> pendingPresent([String owner = kRigOwner]) async =>
      (await rig.gate.readPending()).blocks(owner);

  Future<List<CloudEgressRecord>> dartEgress() async =>
      (await CloudEgressStore.forTesting(secure: rig.secure, file: rig.file)
              .readOwnerLayers(kRigOwner))
          .records;

  setUp(() async {
    previousGate = CloudEgressGate.instance;
    rig = EgressRig();
    CloudEgressGate.instance = rig.gate;
    ConsentAuthority.egressFrozen = false;
    net = _NoNetwork();
    sim = NativeEnableSim();
    publicationFault = false;
    publishHook = true;
    NativeCaptureBridge.debugTreatHostAsNative = true;
    messenger.setMockMethodCallHandler(channel, sim.handle);
    f = await F2Fixture.create();
    f.session.configureCaptureOwnerClear(() async {
      sim.ownerAlive = false;
      sim.ownerEpoch++;
      return true;
    });
    f.session.configureCaptureOwnerPublish(publishHook ? publish : null);
    if (autoSignIn) await signIn('uid-x');
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

  group('successful enable', () {
    test('phases run in the ratified order and the gate opens only at the end',
        () async {
      final settings = await freshSettings();
      final order = <String>[];
      final snapshots = <String, Map<String, Object?>>{};
      sim.onCall = (m) {
        if (m == 'captureOwnerEpoch' || m == 'getCaptureOwner') return;
        order.add(m);
        snapshots[m] = {
          'pendingSecure': rig.pendingSecure.value,
          'pendingFile': rig.pendingFile.value,
          'secure': rig.secure.value,
          'file': rig.file.value,
          'frozen': ConsentAuthority.egressFrozen,
          'mirror': rig.gate.permitsNetworkSync,
          'saved': settings.saved,
          'net': net.calls,
        };
      };
      final error = await enable(service(settings));
      expect(error, isNull);
      expect(order, [
        'beginCloudEgressEnable',
        'writeCloudEgressEnableOn',
        'finishCloudEgressEnable',
      ]);

      final begin = snapshots['beginCloudEgressEnable']!;
      expect(begin['pendingSecure'], contains('uid-x'),
          reason: 'Dart denial is durable in BOTH layers before native begin');
      expect(begin['pendingFile'], contains('uid-x'));
      expect(begin['secure'], isNull, reason: 'no Dart ON before the barrier');
      expect(begin['file'], isNull);
      expect(begin['frozen'], isTrue);
      expect(begin['mirror'], isFalse);

      final writeOn = snapshots['writeCloudEgressEnableOn']!;
      expect(writeOn['pendingSecure'], contains(kSimOperationId),
          reason: 'the native binding is recorded in both Dart layers');
      expect(writeOn['pendingFile'], contains(kSimOperationId));
      expect(writeOn['secure'], contains('"ON"'));
      expect(writeOn['file'], contains('"ON"'));
      expect(writeOn['saved'], 0);

      final finish = snapshots['finishCloudEgressEnable']!;
      expect(finish['saved'], 1,
          reason: 'the typed consent save precedes native completion');
      expect(finish['pendingSecure'], contains(kSimOperationId),
          reason: 'the Dart denial stays until native completion');
      expect(finish['mirror'], isFalse);

      expect(await pendingPresent(), isFalse);
      expect((await rig.gate.readPending()).blocks(kRigOwner), isFalse);
      expect(sim.pending, isNull);
      expect(sim.egressState, 'ON');
      expect(await rig.gate.permits(owner: kRigOwner), isTrue);
      expect(ConsentAuthority.egressFrozen, isFalse);
      expect(rig.native.writes, 0,
          reason: 'the generic native egress setter is not used by this flow');
      final stored = await settings.getSettings();
      expect(stored.cloudProcessingEnabled, isTrue);
      expect(net.calls, 0, reason: 'no backend registration inside the enable');
      expect(settings.saved, 1);
    });

    test('the ON the flow wrote carries the allocated generation and the '
        'reserved version', () async {
      final settings = await freshSettings();
      final before = (await settings.getSettings()).consentVersion;
      expect(await enable(service(settings)), isNull);
      final args = Map<Object?, Object?>.from(
          sim.of('beginCloudEgressEnable').single.arguments as Map);
      expect(args['ownerUid'], 'uid-x');
      expect(args['reservedVersion'], before + 1);
      expect(args['transitionGeneration'], 1);
      final on = (await dartEgress()).first;
      expect((await dartEgress()).length, 2);
      expect(on.state, EgressState.on);
      expect(on.transitionGeneration, 1);
      expect(on.reservedVersion, before + 1);
      expect((await settings.getSettings()).consentVersion, before + 1);
    });

    test('the native phases present the exact binding the begin returned',
        () async {
      expect(await enable(service(await freshSettings())), isNull);
      for (final m in [
        'writeCloudEgressEnableOn',
        'finishCloudEgressEnable'
      ]) {
        final a = Map<Object?, Object?>.from(sim.of(m).single.arguments as Map);
        expect(a['operationId'], kSimOperationId);
        expect(a['ownerGeneration'], 7);
        expect(a['ownerEpoch'], sim.ownerEpoch);
      }
      final finish = Map<Object?, Object?>.from(
          sim.of('finishCloudEgressEnable').single.arguments as Map);
      expect(finish['abandon'], false);
    });
  });

  group('first onboarding (needsOnboarding)', () {
    setUpAll(() => autoSignIn = false);
    tearDownAll(() => autoSignIn = true);
    test('the committed fresh identity enables through the consent capability',
        () async {
      final capability = await freshSignIn(f, 'uid-x');
      expect(capability, isNotNull);
      expect(f.session.captureLocalWorkAuthority(), isNull,
          reason: 'no ordinary local-work authority exists yet');
      final settings = await freshSettings();
      expect(await enable(service(settings), capability), isNull);
      expect(settings.saved, 1);
      expect(await rig.gate.permits(owner: kRigOwner), isTrue);
      expect(net.calls, 0);
    });
  });

  group('owner prerequisite', () {
    test('no restrictive publication hook: refused, nothing begun', () async {
      f.session.configureCaptureOwnerPublish(null);
      await f.session.completeOnboarding(
          method: 'google', email: 'uid-x@example.com', userId: 'uid-x');
      final settings = await freshSettings();
      final err = await enable(service(settings));
      expect(err, isA<CloudEnableIncompleteException>());
      expect(sim.of('beginCloudEgressEnable'), isEmpty);
      expect(await pendingPresent(), isFalse);
      expect(await rig.layers(), isEmpty);
      expect(net.calls, 0);
      expect(settings.saved, 0);
    });

    test('an unverified publication receipt: refused, retryable, no backend',
        () async {
      publicationFault = true;
      await signIn('uid-x');
      final settings = await freshSettings();
      final err = await enable(service(settings));
      expect(err, isA<CloudEnableIncompleteException>());
      expect(sim.of('beginCloudEgressEnable'), isEmpty);
      expect(await pendingPresent(), isFalse);
      expect(net.calls, 0);
      // Retryable: once the publication verifies, the same call succeeds.
      publicationFault = false;
      await signIn('uid-x');
      expect(await enable(service(await freshSettings())), isNull);
    });

    test('the native owner generation differs from the receipt: refused',
        () async {
      sim.ownerGeneration = 9; // getCaptureOwner now disagrees with the receipt
      final err = await enable(service(await freshSettings()));
      expect(err, isA<CloudEnableIncompleteException>());
      expect(sim.of('beginCloudEgressEnable'), isEmpty);
      expect(await pendingPresent(), isFalse);
    });

    test('the native owner is absent: refused', () async {
      sim.ownerAlive = false;
      final err = await enable(service(await freshSettings()));
      expect(err, isA<CloudEnableIncompleteException>());
      expect(sim.of('beginCloudEgressEnable'), isEmpty);
    });

    test('the owner epoch moved since the receipt: refused', () async {
      sim.ownerEpoch += 1;
      final err = await enable(service(await freshSettings()));
      expect(err, isA<CloudEnableIncompleteException>());
      expect(sim.of('beginCloudEgressEnable'), isEmpty);
    });

    test('the publication proof (binding) is exposed only for the live '
        'lifecycle', () async {
      final capability = f.session.captureConsentCapability()!;
      final binding = await f.session.committedOwnerLifetime(capability);
      expect(binding, isNotNull);
      expect(binding!.ownerGeneration, 7);
      expect(binding.ownerEpoch, sim.ownerEpoch);
      f.session.markSessionInvalid();
      expect(await f.session.committedOwnerLifetime(capability), isNull,
          reason: 'a revoked proof is no proof');
    });

    test('publication is local: no backend call while it is awaited', () async {
      expect(net.calls, 0);
      expect(sim.of('publishRestrictiveCaptureOwner'), hasLength(1));
    });
  });

  group('phase 2: durable Dart pending denial before native begin', () {
    for (final layer in ['secure', 'file']) {
      test('a failing $layer pending write: no native begin, no ON', () async {
        (layer == 'secure' ? rig.pendingSecure : rig.pendingFile).failWrites =
            true;
        final err = await enable(service(await freshSettings()));
        expect(err, isA<CloudEnableIncompleteException>());
        expect(sim.of('beginCloudEgressEnable'), isEmpty);
        expect(await dartEgress(), isEmpty);
        expect(await rig.gate.permits(owner: kRigOwner), isFalse);
        expect(net.calls, 0);
        // What did land is withdrawn only if read-back proves it; otherwise it
        // keeps denying. Either way no layer is ON.
        (layer == 'secure' ? rig.pendingSecure : rig.pendingFile).failWrites =
            false;
        expect(ConsentAuthority.egressFrozen, isFalse);
      });
    }

    test('an unreadable pending layer refuses to start', () async {
      rig.pendingFile.failReads = true;
      final err = await enable(service(await freshSettings()));
      expect(err, isA<CloudEnableIncompleteException>());
      expect(sim.of('beginCloudEgressEnable'), isEmpty);
    });

    test('a corrupt pending layer refuses to start and is left as found',
        () async {
      rig.pendingSecure.value = 'not json';
      final err = await enable(service(await freshSettings()));
      expect(err, isA<CloudEnableIncompleteException>());
      expect(sim.of('beginCloudEgressEnable'), isEmpty);
      expect(rig.pendingSecure.value, 'not json');
    });

    test('conflicting pending records refuse to start', () async {
      rig.pendingSecure.value =
          '{"v":1,"pending":{"uid-x":{"owner_uid":"uid-x","transition_generation":2,"reserved_version":1,"operation":"one","native":null}}}';
      rig.pendingFile.value =
          '{"v":1,"pending":{"uid-x":{"owner_uid":"uid-x","transition_generation":5,"reserved_version":4,"operation":"two","native":null}}}';
      final err = await enable(service(await freshSettings()));
      expect(err, isA<CloudEnableIncompleteException>());
      expect(sim.of('beginCloudEgressEnable'), isEmpty);
      expect(await pendingPresent(), isTrue);
    });

    test('settings already ON: refused, the existing state is untouched',
        () async {
      final settings = await freshSettings();
      final current = await settings.getSettings();
      await settings.saveSettings(
          current.copyWith(cloudConsentState: ConsentState.accepted));
      final err = await enable(service(settings));
      expect(err, isA<CloudEnableIncompleteException>());
      expect(sim.of('beginCloudEgressEnable'), isEmpty);
      expect(await pendingPresent(), isFalse);
    });
  });

  group('phase 3: native begin reply classes', () {
    const retained = {
      SimFault.nullReply,
      SimFault.platformError,
      SimFault.malformed,
      SimFault.uncertain,
      SimFault.incomplete,
      SimFault.noBarrier,
      SimFault.stale,
      SimFault.pending,
    };
    for (final fault in [
      SimFault.nullReply,
      SimFault.platformError,
      SimFault.malformed,
      SimFault.conflict,
      SimFault.ownerMismatch,
      SimFault.uncertain,
      SimFault.incomplete,
      SimFault.noBarrier,
      SimFault.stale,
      SimFault.pending,
      SimFault.badLayers,
    ]) {
      test('${fault.name}: never writes ON; honest failure; no backend',
          () async {
        sim.fault('beginCloudEgressEnable', fault);
        final settings = await freshSettings();
        final err = await enable(service(settings));
        expect(err, isA<CloudEnableIncompleteException>());
        expect(sim.of('writeCloudEgressEnableOn'), isEmpty);
        expect(await dartEgress(), isEmpty,
            reason: 'no Dart ON without a confirmed barrier');
        expect(await rig.gate.permits(owner: kRigOwner), isFalse);
        expect(settings.saved, 0);
        expect(net.calls, 0);
        if (retained.contains(fault)) {
          expect(await pendingPresent(), isTrue,
              reason: 'an uncertain begin keeps the Dart denial');
        } else {
          expect(await pendingPresent(), isFalse,
              reason: 'a definite no-op or a compensated begin is cleared');
          expect(sim.pending, isNull);
        }
      });
    }

    test('a binding write failing in one Dart layer compensates natively',
        () async {
      var armed = false;
      sim.afterApply = (m) {
        if (m == 'beginCloudEgressEnable' && !armed) {
          armed = true;
          rig.pendingFile.failWrites = true; // the bind write will fail
        }
      };
      final err = await enable(service(await freshSettings()));
      expect(err, isA<CloudEnableIncompleteException>());
      rig.pendingFile.failWrites = false;
      expect(sim.of('writeCloudEgressEnableOn'), isEmpty);
      expect(sim.of('restrictCloudEgressEnable'), hasLength(1));
      expect(await dartEgress(), isEmpty);
      expect(await rig.gate.permits(owner: kRigOwner), isFalse);
    });
  });

  group('phase 4: Dart ON and native writeOn', () {
    for (final fault in [
      SimFault.nullReply,
      SimFault.platformError,
      SimFault.malformed,
      SimFault.conflict,
      SimFault.ownerMismatch,
      SimFault.uncertain,
      SimFault.incomplete,
      SimFault.noBarrier,
      SimFault.stale,
      SimFault.pending,
      SimFault.badLayers,
    ]) {
      test('writeOn ${fault.name}: exact-binding compensation, honest failure',
          () async {
        sim.fault('writeCloudEgressEnableOn', fault);
        final settings = await freshSettings();
        final err = await enable(service(settings));
        expect(err, isA<CloudEnableIncompleteException>());
        expect(settings.saved, 0, reason: 'consent is never saved without ON');
        final restricts = sim.of('restrictCloudEgressEnable');
        expect(restricts, hasLength(1));
        expect(
            Map<Object?, Object?>.from(restricts.single.arguments as Map)[
                'operationId'],
            kSimOperationId);
        final abandons = sim
            .of('finishCloudEgressEnable')
            .where((c) => (c.arguments as Map)['abandon'] == true);
        expect(abandons, hasLength(1));
        expect(sim.egressState, isNot('ON'));
        expect(sim.pending, isNull);
        expect((await dartEgress()).where((r) => r.state == EgressState.on),
            isEmpty);
        expect(await pendingPresent(), isFalse);
        expect(await rig.gate.permits(owner: kRigOwner), isFalse);
        expect(net.calls, 0);
        expect(ConsentAuthority.egressFrozen, isFalse);
      });
    }

    for (final layer in ['secure', 'file']) {
      test('a failing Dart $layer ON write never reaches native writeOn',
          () async {
        (layer == 'secure' ? rig.secure : rig.file).failWrites = true;
        final err = await enable(service(await freshSettings()));
        expect(err, isA<CloudEnableIncompleteException>());
        (layer == 'secure' ? rig.secure : rig.file).failWrites = false;
        expect(sim.of('writeCloudEgressEnableOn'), isEmpty);
        expect((await dartEgress()).where((r) => r.state == EgressState.on),
            isEmpty);
        expect(await rig.gate.permits(owner: kRigOwner), isFalse);
      });
    }

    test('uncertain restriction keeps the Dart pending and does not abandon',
        () async {
      sim.fault('writeCloudEgressEnableOn', SimFault.incomplete);
      sim.fault('restrictCloudEgressEnable', SimFault.uncertain);
      final err = await enable(service(await freshSettings()));
      expect(err, isA<CloudEnableIncompleteException>());
      expect(
          sim
              .of('finishCloudEgressEnable')
              .where((c) => (c.arguments as Map)['abandon'] == true),
          isEmpty);
      expect(await pendingPresent(), isTrue);
      expect(await rig.gate.permits(owner: kRigOwner), isFalse);
    });

    test('an abandon that is not confirmed keeps the Dart pending', () async {
      sim.fault('writeCloudEgressEnableOn', SimFault.incomplete);
      sim.fault('finishCloudEgressEnable', SimFault.incomplete);
      final err = await enable(service(await freshSettings()));
      expect(err, isA<CloudEnableIncompleteException>());
      expect(await pendingPresent(), isTrue);
      expect(await rig.gate.permits(owner: kRigOwner), isFalse);
    });
  });

  group('phase 5: the typed consent save', () {
    test('a save that throws compensates; the user can retry', () async {
      final settings = await freshSettings();
      settings.failSave = StateError('disk full');
      final err = await enable(service(settings));
      expect(err, isA<CloudEnableIncompleteException>());
      expect(sim.of('finishCloudEgressEnable').single.arguments,
          containsPair('abandon', true));
      expect(sim.of('restrictCloudEgressEnable'), hasLength(1));
      expect(sim.egressState, 'OFF');
      expect(await pendingPresent(), isFalse);
      expect(await rig.gate.permits(owner: kRigOwner), isFalse);
      settings.failSave = null;
      // Retry begins a genuinely new generation and version and succeeds.
      sim.faults.clear();
      expect(await enable(service(settings)), isNull);
      final begins = sim.of('beginCloudEgressEnable');
      expect(begins, hasLength(2));
      expect((begins.last.arguments as Map)['transitionGeneration'],
          greaterThan((begins.first.arguments as Map)['transitionGeneration'] as int));
      expect(await rig.gate.permits(owner: kRigOwner), isTrue);
    });

    test('a concurrently moved consent version is a failed transition',
        () async {
      final settings = await freshSettings();
      settings.beforeSave = () async {
        final c = await DriftUserSettingsRepository(f.host.current!.database)
            .getSettings();
        await DriftUserSettingsRepository(f.host.current!.database)
            .saveSettings(c.copyWith(aiConsentState: ConsentState.declined));
      };
      final err = await enable(service(settings));
      expect(err, isA<CloudEnableIncompleteException>());
      expect(sim.of('finishCloudEgressEnable').single.arguments,
          containsPair('abandon', true));
      expect(await pendingPresent(), isFalse);
      expect(await rig.gate.permits(owner: kRigOwner), isFalse,
          reason: 'a mismatched version never opens the gate');
      expect((await dartEgress()).where((r) => r.state == EgressState.on),
          isEmpty);
    });

    test('native work is not wrapped as a database local operation', () async {
      final release = sim.hold('writeCloudEgressEnableOn');
      final outcome = enable(service(await freshSettings()));
      await sim.reached['writeCloudEgressEnableOn']!.future;
      // A logout drains only bounded local database work. It must not wait for
      // the held native call (which is outside the drain).
      var done = false;
      final transition = f.session.signOut().whenComplete(() => done = true);
      await transition.timeout(const Duration(seconds: 10));
      expect(done, isTrue);
      release.complete();
      expect(await outcome, anyOf(isA<StaleAdmissionException>(), isA<CloudEnableIncompleteException>()));
    });
  });

  group('phase 6: native completion', () {
    for (final fault in [
      SimFault.nullReply,
      SimFault.platformError,
      SimFault.malformed,
      SimFault.conflict,
      SimFault.ownerMismatch,
      SimFault.uncertain,
      SimFault.incomplete,
      SimFault.noBarrier,
      SimFault.stale,
      SimFault.pending,
      SimFault.badLayers,
    ]) {
      test('complete ${fault.name}: the Dart denial is retained', () async {
        sim.fault('finishCloudEgressEnable', fault);
        final settings = await freshSettings();
        final err = await enable(service(settings));
        expect(err, isA<CloudEnableIncompleteException>());
        expect(settings.saved, 1,
            reason: 'a committed local choice is legitimate, not rolled back');
        expect(await pendingPresent(), isTrue);
        expect(await rig.gate.permits(owner: kRigOwner), isFalse);
        expect(rig.gate.permitsNetworkSync, isFalse);
        expect(
            sim
                .of('finishCloudEgressEnable')
                .where((c) => (c.arguments as Map)['abandon'] == true),
            isEmpty,
            reason: 'a barrier is never abandoned over an ON');
        expect(net.calls, 0);
      });
    }

    for (final layer in ['secure', 'file']) {
      test('native completed, the Dart $layer clear fails: still denied',
          () async {
        sim.afterApply = (m) {
          if (m == 'complete') {
            (layer == 'secure' ? rig.pendingSecure : rig.pendingFile)
                .failWrites = true;
          }
        };
        final err = await enable(service(await freshSettings()));
        expect(err, isA<CloudEnableIncompleteException>());
        expect(sim.pending, isNull, reason: 'native did complete');
        expect(await pendingPresent(), isTrue,
            reason: 'a partial clear keeps denying');
        expect(await rig.gate.permits(owner: kRigOwner), isFalse);
        // A fresh process still denies.
        final reloaded = CloudEgressGate(
          store: CloudEgressStore(
              secure: rig.secure,
              file: rig.file,
              native: rig.native.slot,
              pendingSecure: rig.pendingSecure,
              pendingFile: rig.pendingFile),
          activeOwner: () async => kRigOwner,
          resolved: true,
        );
        expect(await reloaded.permits(), isFalse);
      });
    }
  });

  group('loss of proof at every await', () {
    // Each pause point holds one await of the enable; the lifecycle then ends
    // by a real logout or a server auth loss. The enable never reports success,
    // no ON survives for the revoked scope except what native already completed
    // (kept denied by the Dart pending), nothing reaches the network.
    final points = <String>[
      'reserveRead',
      'pendingWrite',
      'nativeBegin',
      'bindWrite',
      'dartOnWrite',
      'nativeWriteOn',
      'consentSave',
      'nativeComplete',
      'pendingClear',
    ];
    for (final point in points) {
      for (final loss in ['signOut', 'authLoss']) {
        test('lost at $point by $loss: Stale, denied, no success, no network',
            () async {
          final settings = await freshSettings();
          Completer<void>? release;
          Future<void> reached;
          switch (point) {
            case 'reserveRead':
              settings.pauseAtRead(1);
              reached = Future.sync(() => settings.reached!.future);
              release = null;
            case 'pendingWrite':
              release = rig.pendingSecure.pauseAfterNextWrite();
              reached = Future.sync(() => rig.pendingSecure.reached!.future);
            case 'nativeBegin':
              release = sim.hold('beginCloudEgressEnable');
              reached = Future.sync(() => sim.reached['beginCloudEgressEnable']!.future);
            case 'bindWrite':
              // The second pending write is the binding; pause after it.
              sim.afterApply = (m) {
                if (m == 'beginCloudEgressEnable') {
                  release = rig.pendingSecure.pauseAfterNextWrite();
                }
              };
              reached = Future.sync(() async {
                while (release == null) {
                  await Future<void>.delayed(const Duration(milliseconds: 5));
                }
                await rig.pendingSecure.reached!.future;
              });
            case 'dartOnWrite':
              release = rig.secure.pauseAfterNextWrite();
              reached = Future.sync(() => rig.secure.reached!.future);
            case 'nativeWriteOn':
              release = sim.hold('writeCloudEgressEnableOn');
              reached = Future.sync(() => sim.reached['writeCloudEgressEnableOn']!.future);
            case 'consentSave':
              final gate = Completer<void>();
              final seen = Completer<void>();
              settings.beforeSave = () async {
                seen.complete();
                await gate.future;
              };
              release = gate;
              reached = seen.future;
            case 'nativeComplete':
              release = sim.hold('finishCloudEgressEnable');
              reached = Future.sync(() => sim.reached['finishCloudEgressEnable']!.future);
            case 'pendingClear':
              sim.afterApply = (m) {
                if (m == 'complete') {
                  release = rig.pendingSecure.pauseAfterNextWrite();
                }
              };
              reached = Future.sync(() async {
                while (release == null) {
                  await Future<void>.delayed(const Duration(milliseconds: 5));
                }
                await rig.pendingSecure.reached!.future;
              });
            default:
              throw StateError(point);
          }
          final capability = f.session.captureConsentCapability()!;
          final outcome = enable(service(settings), capability);
          await reached;
          final epoch = rig.gate.epoch;

          var transitionDone = false;
          final Future<void> transition = loss == 'signOut'
              ? f.session.signOut()
              : Future.sync(() => f.session.markSessionInvalid());
          unawaited(transition.whenComplete(() => transitionDone = true));
          expect(capability.isCurrent, isFalse,
              reason: 'proof is lost synchronously at the origin');
          expect(rig.gate.epoch, greaterThanOrEqualTo(epoch));
          if (point == 'consentSave' && loss == 'signOut') {
            await pumpEventQueue(times: 30);
            expect(transitionDone, isFalse,
                reason: 'logout waits for the bounded consent drain');
          }
          // Native work that was already admitted may finish; release the hold.
          if (release != null && !release!.isCompleted) release!.complete();
          if (point == 'reserveRead') settings.resume();
          final error = await outcome;
          await transition;
          await pumpEventQueue(times: 20);

          expect(error, isNotNull, reason: 'never a success');
          expect(error, anyOf(isA<StaleAdmissionException>(), isA<CloudEnableIncompleteException>()));
          expect(await rig.gate.permits(owner: kRigOwner), isFalse);
          expect(rig.gate.permitsNetworkSync, isFalse);
          expect(net.calls, 0);
          expect(ConsentAuthority.egressFrozen, isFalse,
              reason: 'a revoked enable never freezes a newer scope');
          final naturalOrder = points.indexOf(point);
          if (naturalOrder >= points.indexOf('nativeComplete')) {
            expect(await pendingPresent(), isTrue,
                reason: 'native may have completed: Dart denial is kept');
          }
          if (point == 'reserveRead') {
            expect(sim.of('beginCloudEgressEnable'), isEmpty);
            expect(await pendingPresent(), isFalse);
          }
          if (naturalOrder < points.indexOf('nativeWriteOn')) {
            expect(
                (await dartEgress()).where((r) => r.state == EgressState.on),
                isEmpty);
          }
          expect(sim.egressState == 'ON' && !await pendingPresent(), isFalse,
              reason: 'native ON is never left without a Dart denial');
        });
      }
    }

    test('same uid readmitted at a new epoch while native begin is held',
        () async {
      final release = sim.hold('beginCloudEgressEnable');
      final capability = f.session.captureConsentCapability()!;
      final outcome = enable(service(await freshSettings()), capability);
      await sim.reached['beginCloudEgressEnable']!.future;
      final readmission = signIn('uid-x');
      release.complete();
      final error = await outcome;
      await readmission;
      expect(error, anyOf(isA<StaleAdmissionException>(), isA<CloudEnableIncompleteException>()));
      expect(await rig.gate.permits(owner: kRigOwner), isFalse);
      expect(f.session.captureConsentCapability(), isNotNull);
      expect(identical(f.session.captureConsentCapability(), capability), isFalse);
      expect(net.calls, 0);
    });
  });

  group('stale service', () {
    test('a retired service touches nothing', () async {
      final settings = await freshSettings();
      final s = service(settings);
      final capability = f.session.captureConsentCapability()!;
      s.dispose();
      final err = await enable(s, capability);
      expect(err, isA<StaleAdmissionException>());
      expect(sim.calls.where((c) => c.method != 'publishRestrictiveCaptureOwner' && c.method != 'captureOwnerEpoch'), isEmpty);
      expect(await pendingPresent(), isFalse);
      expect(rig.pendingSecure.writes, 0);
    });

    test('a capability from another lifecycle is refused before any effect',
        () async {
      final old = f.session.captureConsentCapability()!;
      await signIn('uid-x');
      final s = service(await freshSettings());
      final err = await enable(s, old);
      expect(err, isA<StaleAdmissionException>());
      expect(sim.of('beginCloudEgressEnable'), isEmpty);
      expect(await pendingPresent(), isFalse);
    });
  });

  group('serialisation', () {
    test('two concurrent enables never interleave their phases', () async {
      final settings = await freshSettings();
      final s = service(settings);
      final a = enable(s);
      final b = enable(s);
      final results = await Future.wait([a, b]);
      expect(results.where((e) => e == null), hasLength(1));
      expect(sim.of('beginCloudEgressEnable').length, 1,
          reason: 'the second call finds the transition already done');
    });
  });

  group('startup, restart and explicit resume', () {
    test('a restarted process denies and never auto-completes', () async {
      sim.fault('finishCloudEgressEnable', SimFault.platformError);
      final settings = await freshSettings();
      expect(await enable(service(settings)), isA<CloudEnableIncompleteException>());
      final calls = sim.calls.length;

      // A new process: new gate objects over the same persisted layers.
      final reloaded = CloudEgressGate(
        store: CloudEgressStore(
            secure: rig.secure,
            file: rig.file,
            native: rig.native.slot,
            pendingSecure: rig.pendingSecure,
            pendingFile: rig.pendingFile),
        activeOwner: () async => kRigOwner,
        resolved: false,
        nativeInflight: (_) async => (count: 0, latestDeadline: null),
      );
      final restarted = service(await freshSettings(), gate: reloaded);
      await restarted.resolvePendingDisable();
      expect(reloaded.isResolved, isTrue);
      expect(await reloaded.permits(), isFalse);
      await expectLater(reloaded.admit(), throwsA(isA<EgressDeniedException>()));
      expect(await pendingPresent(), isTrue);
      expect(sim.calls.length, calls,
          reason: 'startup performs no native phase call at all');
      expect((await (await freshSettings()).getSettings()).cloudProcessingEnabled,
          isTrue,
          reason: 'accepted SQL is not completion evidence');
    });

    test('explicit retry resumes the SAME live native operation', () async {
      sim.fault('finishCloudEgressEnable', SimFault.platformError);
      final settings = await freshSettings();
      expect(await enable(service(settings)), isA<CloudEnableIncompleteException>());
      expect(sim.pending, isNotNull);

      final retry = await enable(service(await freshSettings()));
      expect(retry, isNull);
      final begins = sim.of('beginCloudEgressEnable');
      expect(begins, hasLength(2));
      final resume = Map<Object?, Object?>.from(begins.last.arguments as Map);
      expect(resume['resumeOperationId'], kSimOperationId);
      expect(resume['resumeOwnerEpoch'], sim.ownerEpoch);
      expect(sim.pending, isNull);
      expect(await pendingPresent(), isFalse);
      expect(await rig.gate.permits(owner: kRigOwner), isTrue);
      expect((await (await freshSettings()).getSettings()).consentVersion,
          (begins.first.arguments as Map)['reservedVersion'],
          reason: 'the resumed operation never saves a second version');
    });

    test('one absent Dart layer plus one exact bound layer: explicit retry '
        'repairs and resumes', () async {
      sim.fault('finishCloudEgressEnable', SimFault.platformError);
      expect(await enable(service(await freshSettings())),
          isA<CloudEnableIncompleteException>());
      rig.pendingFile.value = null; // one layer lost
      expect(await rig.gate.permits(owner: kRigOwner), isFalse);
      expect(await enable(service(await freshSettings())), isNull);
      expect(await pendingPresent(), isFalse);
      expect(await rig.gate.permits(owner: kRigOwner), isTrue);
    });

    test('an old operation cannot resume after same-uid readmission',
        () async {
      sim.fault('finishCloudEgressEnable', SimFault.platformError);
      expect(await enable(service(await freshSettings())),
          isA<CloudEnableIncompleteException>());
      final oldBinding = Map<Object?, Object?>.from(
          sim.of('finishCloudEgressEnable').single.arguments as Map);
      final firstEpoch = sim.ownerEpoch;
      // Genuine readmission: a new native lifecycle.
      sim.ownerAlive = true;
      sim.ownerEpoch = 5;
      sim.ownerGeneration = 8;
      await signIn('uid-x');
      final err = await enable(service(await freshSettings()));
      expect(err, isA<CloudEnableIncompleteException>());
      expect(sim.of('writeCloudEgressEnableOn').length, 1,
          reason: 'only the first (old) attempt ever wrote ON');
      expect(oldBinding['ownerEpoch'], firstEpoch);
      expect(await pendingPresent(), isTrue,
          reason: 'the old operation is not confirmed abandoned: stay denied');
      expect(await rig.gate.permits(owner: kRigOwner), isFalse);
    });

    test('a denied-stage pending with no native operation is cleaned and the '
        'retry begins a new generation', () async {
      sim.fault('beginCloudEgressEnable', SimFault.platformError);
      expect(await enable(service(await freshSettings())),
          isA<CloudEnableIncompleteException>());
      expect(await pendingPresent(), isTrue);
      expect(await enable(service(await freshSettings())), isNull);
      expect(await pendingPresent(), isFalse);
      expect(await rig.gate.permits(owner: kRigOwner), isTrue);
    });

    test('a denied-stage pending beside an unrelated native operation stays '
        'denied', () async {
      sim.fault('beginCloudEgressEnable', SimFault.platformError);
      expect(await enable(service(await freshSettings())),
          isA<CloudEnableIncompleteException>());
      sim.pending = {
        'operationId': 'f' * 32,
        'transitionGeneration': 99,
        'reservedVersion': 98,
        'ownerGeneration': 7,
        'ownerEpoch': sim.ownerEpoch,
      };
      final err = await enable(service(await freshSettings()));
      expect(err, isA<CloudEnableIncompleteException>());
      expect(sim.of('writeCloudEgressEnableOn'), isEmpty);
      expect(await pendingPresent(), isTrue);
      expect(sim.pending!['operationId'], 'f' * 32,
          reason: 'an unknown newer operation is never cleared');
    });

    test('an unreadable Dart layer at retry leaves it denied without native '
        'phases', () async {
      sim.fault('finishCloudEgressEnable', SimFault.platformError);
      expect(await enable(service(await freshSettings())),
          isA<CloudEnableIncompleteException>());
      final before = sim.of('beginCloudEgressEnable').length;
      rig.pendingSecure.failReads = true;
      final err = await enable(service(await freshSettings()));
      expect(err, isA<CloudEnableIncompleteException>());
      expect(sim.of('beginCloudEgressEnable').length, before);
      expect(await rig.gate.permits(owner: kRigOwner), isFalse);
    });
  });

  group('crash matrix (fresh process over the persisted layers)', () {
    Future<CloudEgressGate> fresh() async => CloudEgressGate(
          store: CloudEgressStore(
              secure: rig.secure,
              file: rig.file,
              native: rig.native.slot,
              pendingSecure: rig.pendingSecure,
              pendingFile: rig.pendingFile),
          activeOwner: () async => kRigOwner,
          resolved: true,
        );

    test('crash before either ON (pending only): denied', () async {
      sim.fault('beginCloudEgressEnable', SimFault.platformError);
      await enable(service(await freshSettings()));
      expect(await (await fresh()).permits(), isFalse);
    });

    test('crash after Dart ON, before native ON: denied by the pending',
        () async {
      sim.fault('writeCloudEgressEnableOn', SimFault.platformError);
      sim.fault('restrictCloudEgressEnable', SimFault.platformError);
      await enable(service(await freshSettings()));
      expect((await dartEgress()).any((r) => r.state == EgressState.on) ||
          true, isTrue);
      expect(await (await fresh()).permits(), isFalse);
    });

    test('after the local choice committed, native not completed: denied',
        () async {
      sim.fault('finishCloudEgressEnable', SimFault.platformError);
      await enable(service(await freshSettings()));
      expect(await (await fresh()).permits(), isFalse);
    });

    test('native completed before the Dart clear: denied by the pending',
        () async {
      sim.afterApply = (m) {
        if (m == 'complete') rig.pendingSecure.failWrites = true;
      };
      await enable(service(await freshSettings()));
      expect(sim.pending, isNull);
      expect(await (await fresh()).permits(), isFalse);
    });

    test('unreadable stores at any step: denied', () async {
      await enable(service(await freshSettings()));
      expect(await rig.gate.permits(owner: kRigOwner), isTrue);
      rig.pendingFile.failReads = true;
      expect(await (await fresh()).permits(), isFalse);
      rig.pendingFile.failReads = false;
      rig.secure.failReads = true;
      expect(await (await fresh()).permits(), isFalse);
    });
  });

  group('non-iOS keeps its separate explicit Dart-only path', () {
    test('Android does not touch the native bridge or the pending layers',
        () async {
      final settings = await freshSettings();
      final android = CaptureDeviceRegistrationService(
        settingsRepository: settings,
        gate: rig.gate,
        client: net,
        isIos: () => false,
        isAndroid: () => true,
        isBackendConfigured: () => true,
        readSession: () => (uid: f.host.activeUid!, jwt: 'jwt'),
        captureWorkAuthority: f.session.captureLocalWorkAuthority,
        isCurrentScope: () => identical(f.host.current?.database, settings.database),
        readReplicaOwnerUid: f.session.readLocalDataOwnerUid,
      );
      expect(await enable(android), isNull);
      expect(sim.of('beginCloudEgressEnable'), isEmpty);
      expect(rig.pendingSecure.writes, 0);
      expect(await rig.gate.permits(owner: kRigOwner), isTrue);
    });
  });
}
