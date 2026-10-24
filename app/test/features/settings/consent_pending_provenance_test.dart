import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/core/privacy/consent_authority.dart';
import 'package:money_companion/core/privacy/diagnostics_consent_gate.dart';
import 'package:money_companion/core/session/admission_authority.dart';
import 'package:money_companion/core/session/consent_capability.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/features/capture/services/capture_backend_client.dart';
import 'package:money_companion/features/capture/services/capture_device_registration_service.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';
import 'package:money_companion/features/coupons/coupons_providers.dart';
import 'package:money_companion/features/settings/privacy_screen.dart';
import 'package:money_companion/features/settings/settings_providers.dart';
import 'package:money_companion/l10n/app_localizations.dart';

import '../../core/session/f2_fixture.dart';
import '../../harness/native_enable_sim.dart';
import '../../harness/paused_egress_support.dart';
import '../consent/consent_test_harness.dart';

// N-CR-4 (Astra R6): the Privacy card with the REAL facts provider, service,
// gate, session and per-uid Drift replica, for stored OFF and stored ON crossed
// with corrupt, unreadable, conflicting and one-layer Dart pending evidence.
// Unresolved provenance is shown as "Can't confirm" with only supported actions;
// corrupt or conflicting evidence is never erased automatically; a one-layer
// pending still has its working withdrawal. Only the platform edge (native
// channel stand-in, network client) is scripted.

final _en = lookupAppL10n(const Locale('en'));

class _Spy extends DriftUserSettingsRepository {
  _Spy(AppDatabase db)
      : database = db,
        super(db);
  final AppDatabase database;
  int saved = 0;
  @override
  Future<UserSettingsEntity> saveConsentChoice(
      ConsentCapability capability, ConsentChoices choices) async {
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
  late CloudEgressGate gate;
  late _Spy settings;
  late CaptureDeviceRegistrationService service;

  Future<RestrictiveCaptureOwnerReceipt?> publish(
      String uid, AdmissionAuthority authority) async {
    final epoch = await NativeCaptureBridge.captureOwnerEpoch();
    return NativeCaptureBridge.publishRestrictiveCaptureOwner(
        uid: uid, version: 0, expectedEpoch: epoch);
  }

  Future<void> boot(WidgetTester tester, {bool nativeGate = false}) async {
    await tester.runAsync(() async {
      previousGate = CloudEgressGate.instance;
      NativeCaptureBridge.debugTreatHostAsNative = true;
      rig = EgressRig();
      // The rig's scripted native egress slot is not wired to the native enable
      // stand-in (the sim owns the native ON), so the gate here reads only the
      // Dart layers; the sim is the native side.
      gate = CloudEgressGate(
        store: CloudEgressStore(
            secure: rig.secure,
            file: rig.file,
            // R18: the production shape, the native egress layer reached through
            // the channel (the simulator is then the single native truth).
            native: nativeGate ? NativeEgressSlot.platformDefault() : null,
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
      final sdk = await F2Fixture.liveClient('uid-x');
      f.session.configureConsentSdkClient(() => sdk);
      await f.signIn('uid-x');
      settings = _Spy(f.host.current!.database);
      service = CaptureDeviceRegistrationService(
        settingsRepository: settings,
        gate: gate,
        client: net,
        isIos: () => true,
        isBackendConfigured: () => false,
        readSession: () => f.host.activeUid == null
            ? null
            : (uid: f.host.activeUid!, jwt: 'jwt'),
        captureWorkAuthority: f.session.captureLocalWorkAuthority,
        isCurrentScope: () =>
            identical(f.host.current?.database, settings.database),
        readReplicaOwnerUid: f.session.readLocalDataOwnerUid,
      );
    });
    addTearDown(() async {
      await tester.runAsync(() async {
        for (final h in sim.holds.values) {
          if (!h.isCompleted) h.complete();
        }
        await pumpEventQueue(times: 30);
        f.session.configureCaptureOwnerPublish(null);
        f.session.debugResetAdmissionState();
        await f.dispose();
      });
      NativeCaptureBridge.debugTreatHostAsNative = false;
      messenger.setMockMethodCallHandler(channel, null);
      ConsentAuthority.egressFrozen = false;
      CloudEgressGate.instance = previousGate;
      DiagnosticsConsentGate.resetForTest();
    });
  }

  Future<T> io<T>(WidgetTester tester, Future<T> Function() body) async {
    T? result;
    await tester.runAsync(() async => result = await body());
    return result as T;
  }

  /// Lets real I/O and the frames it schedules run to quiescence.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 25; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  /// Like [settle], but stops as soon as [finder] matches (a toast only lives
  /// three seconds of frame time).
  Future<void> settleUntil(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 25 && finder.evaluate().isEmpty; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 2000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(consentApp(
      overrides: [
        appDatabaseProvider.overrideWithValue(f.host.current!.database),
        userSettingsRepositoryProvider.overrideWithValue(settings),
        consentSettingsWriterProvider.overrideWithValue(settings),
        userSettingsProvider.overrideWith((_) => settings.getSettings()),
        captureDeviceRegistrationServiceProvider.overrideWithValue(service),
        merchantOffersEnabledProvider.overrideWithValue(false),
      ],
      home: const PrivacyScreen(),
    ));
    await settle(tester);
  }

  Finder status(String text) => find.descendant(
      of: find.byKey(const Key('consentStatus')), matching: find.text(text));
  Finder turnOn() => find.byKey(const Key('consentTurnOn'));
  Finder turnOff() => find.byKey(const Key('consentTurnOff'));


  const cloudOnly = ConsentChoices(
      cloud: ConsentState.accepted, ai: ConsentState.declined);

  /// Stored ON (committed) with the Dart and native pending still in place.
  Future<void> storedOnWithPending(WidgetTester tester) async {
    sim.fault('finishCloudEgressEnable', SimFault.nullReply);
    final err = await io(
        tester,
        () => service
            .enableCloud(
                write: ConsentWrite(
                    f.session.captureConsentCapability()!, cloudOnly))
            .then<Object?>((_) => null, onError: (Object e) => e));
    expect(err, isA<CloudEnableIncompleteException>());
    expect((await io(tester, settings.getSettings)).cloudProcessingEnabled,
        isTrue);
  }

  /// Stored OFF with only the Dart denial (native `begin` never answered).
  Future<void> storedOffWithPending(WidgetTester tester) async {
    sim.fault('beginCloudEgressEnable', SimFault.nullReply);
    final err = await io(
        tester,
        () => service
            .enableCloud(
                write: ConsentWrite(
                    f.session.captureConsentCapability()!, cloudOnly))
            .then<Object?>((_) => null, onError: (Object e) => e));
    expect(err, isA<CloudEnableIncompleteException>());
    expect((await io(tester, settings.getSettings)).cloudProcessingEnabled,
        isFalse);
  }

  String conflicting(PendingEnableRecord rec) =>
      '{"v":1,"pending":{"uid-x":{"owner_uid":"uid-x","transition_generation":'
      '${rec.transitionGeneration + 5},"reserved_version":${rec.reservedVersion},'
      '"operation":"other","native":null}}}';

  final unresolvedKinds = <String, Future<void> Function(WidgetTester)>{
    'corrupt': (t) async => rig.pendingSecure.value = 'not json',
    'unreadable': (t) async => rig.pendingFile.failReads = true,
    'conflicting': (t) async {
      final rec = (await io(t, () => gate.readPending())).agreed('uid-x')!;
      rig.pendingFile.value = conflicting(rec);
    },
  };

  group('N-CR-4 unresolved pending provenance', () {
    for (final stored in ['OFF', 'ON']) {
      for (final kind in unresolvedKinds.entries) {
        testWidgets('stored $stored x ${kind.key} pending: "Can\'t confirm", '
            'no Turn on, no Turn off that cannot clear it, no instruction to '
            'withdraw; the evidence is left untouched', (tester) async {
          await boot(tester, nativeGate: true);
          if (stored == 'ON') {
            await storedOnWithPending(tester);
          } else {
            await storedOffWithPending(tester);
          }
          await kind.value(tester);
          final secureBefore = rig.pendingSecure.value;
          final fileBefore = rig.pendingFile.value;
          final savedBefore = settings.saved;
          await pumpScreen(tester);

          expect(status(_en.consentStatusUnknown), findsOneWidget);
          expect(status(_en.consentStatusOff), findsNothing);
          expect(status(_en.consentStatusActive), findsNothing);
          expect(status(_en.consentStatusTurningOn), findsNothing);
          expect(turnOn(), findsNothing,
              reason: 'the enable route refuses (withdraw first)');
          expect(turnOff(), findsNothing,
              reason: 'the withdrawal knows it cannot clear this evidence');
          expect(find.text(_en.consentStatusUnknownRecovery), findsNothing,
              reason: 'no instruction that cannot succeed');
          expect(find.byKey(const Key('consentRefresh')), findsOneWidget);

          // Never erased or rewritten by merely showing it.
          expect(rig.pendingSecure.value, secureBefore);
          expect(rig.pendingFile.value, fileBefore);
          expect(settings.saved, savedBefore);
          expect(net.calls, 0);
        });
      }

      testWidgets('stored $stored x unresolved: the service refuses the '
          'withdrawal and clears nothing', (tester) async {
        await boot(tester, nativeGate: true);
        if (stored == 'ON') {
          await storedOnWithPending(tester);
        } else {
          await storedOffWithPending(tester);
        }
        rig.pendingSecure.value = 'not json';
        final w = f.session.captureConsentCapability()!;
        final err = await io(
            tester,
            () => service
                .withdrawPendingEnable(
                    capability: w, commitLocalOff: () async {})
                .then<Object?>((_) => null, onError: (Object e) => e));
        expect(err, isA<CloudWithdrawIncompleteException>());
        expect(rig.pendingSecure.value, 'not json');
        expect(rig.pendingFile.value, isNotNull);
        expect(await io(tester, () => service.pendingProvenanceUnresolved(
            ownerUid: 'uid-x')), isTrue);
      });
    }

    testWidgets('a healthy resumable pending is not reported unresolved',
        (tester) async {
      await boot(tester, nativeGate: true);
      await storedOnWithPending(tester);
      expect(
          await io(tester,
              () => service.pendingProvenanceUnresolved(ownerUid: 'uid-x')),
          isFalse);
      await pumpScreen(tester);
      expect(status(_en.consentStatusTurningOn), findsOneWidget);
      expect(turnOn(), findsOneWidget);
      expect(turnOff(), findsOneWidget);
    });
  });

  // N-PV (Astra R7 Q13): native pending evidence can survive on its own (a
  // partial persistence or a crash). The facts provider must inspect the native
  // runtime INDEPENDENTLY of whether the Dart pending is present, classify the
  // uncertainty and offer only supported actions. Nothing is fabricated for the
  // Dart side and no native operation is abandoned by showing it.
  Future<void> nativeOnlyPending(WidgetTester tester, String stored) async {
    await storedOnWithPending(tester);
    // The Dart pending is gone (both layers); the native barrier remains.
    rig.pendingSecure.value = null;
    rig.pendingFile.value = null;
    // A restart: the in-process pending marker of the earlier enable is gone;
    // only the durable evidence (here, the native barrier) remains.
    await io(tester, () => gate.thawEnable('uid-x'));
    ConsentAuthority.egressFrozen = false;
    if (stored == 'OFF') {
      await io(
          tester,
          () => settings.saveConsentChoice(
              f.session.captureConsentCapability()!,
              const ConsentChoices(
                  cloud: ConsentState.declined, ai: ConsentState.declined)));
    }
    expect(sim.pending, isNotNull);
    expect((await io(tester, () => gate.readPending())).blocks('uid-x'),
        isFalse);
  }

  final nativeKinds = <String, void Function()>{
    'pending (no Dart record to attribute it to)': () {},
    'corrupt/conflicting layers': () => sim.pendingLayersConflict = true,
    'one layer only': () => sim.pendingOnlyInLayer = 'file',
    'unreadable': () {
      for (var i = 0; i < 12; i++) {
        sim.fault('getCloudEgressPending', SimFault.platformError);
      }
    },
    'owner mismatch': () {
      for (var i = 0; i < 12; i++) {
        sim.fault('getCloudEgressPending', SimFault.ownerMismatch);
      }
    },
  };

  group('N-PV native-only pending provenance', () {
    for (final stored in ['OFF', 'ON']) {
      for (final kind in nativeKinds.entries) {
        testWidgets('stored $stored x absent Dart x native ${kind.key}: '
            '"Can\'t confirm", no Turn on, no Turn off, nothing erased',
            (tester) async {
          await boot(tester, nativeGate: true);
          await nativeOnlyPending(tester, stored);
          kind.value();
          final nativeBefore = Map.of(sim.pending!);
          final savedBefore = settings.saved;
          expect(
              await io(
                  tester,
                  () => service.pendingProvenanceUnresolved(
                      ownerUid: 'uid-x')),
              isTrue);
          await pumpScreen(tester);

          expect(status(_en.consentStatusUnknown), findsOneWidget);
          expect(status(_en.consentStatusOff), findsNothing);
          expect(status(_en.consentStatusActive), findsNothing);
          expect(turnOn(), findsNothing);
          expect(turnOff(), findsNothing);
          expect(find.text(_en.consentStatusUnknownRecovery), findsNothing);
          expect(find.byKey(const Key('consentRefresh')), findsOneWidget);
          // Not abandoned, no Dart evidence invented, nothing saved or sent.
          expect(sim.pending, nativeBefore);
          expect(sim.of('finishCloudEgressEnable'), hasLength(1),
              reason: 'only the original, unconfirmed completion');
          expect(rig.pendingSecure.value, isNull);
          expect(rig.pendingFile.value, isNull);
          expect(settings.saved, savedBefore);
          expect(net.calls, 0);
        });
      }

      testWidgets('stored $stored x absent Dart x native pending, after a '
          'restart (a new facts read): still unresolved, still untouched',
          (tester) async {
        await boot(tester, nativeGate: true);
        await nativeOnlyPending(tester, stored);
        ConsentAuthority.egressFrozen = false; // a new process
        await pumpScreen(tester);
        expect(status(_en.consentStatusUnknown), findsOneWidget);
        expect(turnOn(), findsNothing);
        expect(turnOff(), findsNothing);
        expect(sim.pending, isNotNull);
        expect(sim.of('finishCloudEgressEnable'), hasLength(1));
      });

      testWidgets('stored $stored x absent Dart x no native pending: nothing '
          'is reported unresolved', (tester) async {
        await boot(tester, nativeGate: true);
        await nativeOnlyPending(tester, stored);
        sim.pending = null; // native completed/abandoned on its own
        expect(
            await io(
                tester,
                () => service.pendingProvenanceUnresolved(ownerUid: 'uid-x')),
            isFalse);
      });
    }

    testWidgets('no native runtime exists: absent Dart pending stays '
        'resolved and nothing native is inspected', (tester) async {
      await boot(tester);
      NativeCaptureBridge.debugTreatHostAsNative = false;
      expect(
          await io(tester,
              () => service.pendingProvenanceUnresolved(ownerUid: 'uid-x')),
          isFalse);
      expect(sim.of('getCloudEgressPending'), isEmpty);
    });
  });

  group('N-CR-4 one-layer pending keeps its working withdrawal', () {
    for (final stored in ['OFF', 'ON']) {
      testWidgets('stored $stored x one-layer pending: Turning on with Turn '
          'on (exact resume) and Turn off; the withdrawal clears it and ends Off',
          (tester) async {
        await boot(tester, nativeGate: true);
        if (stored == 'ON') {
          await storedOnWithPending(tester);
        } else {
          await storedOffWithPending(tester);
        }
        rig.pendingFile.value = null; // only the secure layer holds it
        await pumpScreen(tester);
        expect(status(_en.consentStatusTurningOn), findsOneWidget);
        // One readable exact record is attributable: the exact resume (repair)
        // and the withdrawal are both supported; no recovery hint is needed.
        expect(turnOn(), findsOneWidget);
        expect(turnOff(), findsOneWidget);
        expect(find.text(_en.consentStatusUnknownRecovery), findsNothing);

        await tester.ensureVisible(turnOff());
        await tester.tap(turnOff());
        await settle(tester);
        await tester.tap(find.byKey(const Key('consentWithdrawConfirm')));
        await settle(tester);
        expect(
            (await io(tester, () => gate.readPending())).blocks('uid-x'),
            isFalse);
        expect(sim.pending, isNull);
        expect(status(_en.consentStatusOff), findsOneWidget);
        expect(turnOn(), findsOneWidget);
      });
    }

    testWidgets('a withdrawal that cannot verify native restriction fails '
        'honestly: toast, evidence kept, still Turning on', (tester) async {
      await boot(tester, nativeGate: true);
      await storedOnWithPending(tester);
      rig.pendingFile.value = null;
      sim.failEgressWrites = true;
      await pumpScreen(tester);
      await tester.ensureVisible(turnOff());
      await tester.tap(turnOff());
      await settle(tester);
      await tester.tap(find.byKey(const Key('consentWithdrawConfirm')));
      await settleUntil(tester, find.text(_en.consentWithdrawFailed));
      expect(find.text(_en.consentWithdrawFailed), findsOneWidget);
      expect(rig.pendingSecure.value, isNotNull);
      expect(sim.pending, isNotNull);
      expect(status(_en.consentStatusOff), findsNothing);
      expect(status(_en.consentStatusTurningOn), findsOneWidget);
      expect(turnOff(), findsOneWidget, reason: 'a retry is still possible');
      await tester.pump(const Duration(seconds: 4)); // the toast timer
    });
  });
}
