import 'dart:async';

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

import '../../core/session/f2_fixture.dart';
import '../../harness/paused_egress_support.dart';

// Task 01 — an explicit Cloud enable crossing a REAL AppSession transition. The
// real service runs its bounded local work inside the session's admission drain,
// over the real gate and a real per-uid replica. For every pause point (initial
// settings read, gate store write, local commit) and every transition (logout,
// Remove data, another uid, the same uid readmitted at a new epoch) the stale
// enable must leave nothing ON, never touch the newer scope, never use the
// network, and never report success.

class _PausingSettings extends DriftUserSettingsRepository {
  _PausingSettings(super.db, {super.afterConsentFinalGuard});
  Completer<void>? reached;
  Completer<void>? _release;
  int? _pauseAtRead;

  /// getSettings calls so far (the service's own read is #1; the typed
  /// transaction's first read is #2).
  int reads = 0;

  /// Typed consent saves that COMPLETED (a rolled-back one never counts).
  int saved = 0;

  void pause() => pauseAtRead(reads + 1);

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

CaptureDeviceRegistrationService _service(F2Fixture f, AppDatabase db,
        DriftUserSettingsRepository settings, EgressRig rig, _NoNetwork net) =>
    CaptureDeviceRegistrationService(
      settingsRepository: settings,
      gate: rig.gate,
      client: net,
      isIos: () => true,
      isBackendConfigured: () => true,
      readSession: () => f.host.activeUid == null
          ? null
          : (uid: f.host.activeUid!, jwt: 'jwt'),
      captureWorkAuthority: f.session.captureLocalWorkAuthority,
      isCurrentScope: () => identical(f.host.current?.database, db),
      readReplicaOwnerUid: f.session.readLocalDataOwnerUid,
      readOwnerEpoch: () async => 0,
      publishOwner: ({
        required uid,
        required cloud,
        required ai,
        required version,
        required expectedEpoch,
        transitionGeneration,
      }) async {},
    );

enum _Point { settingsRead, storeWrite, localCommit }

enum _Transition { signOut, removeData, switchUid, sameUidReadmission }

Future<void> _acceptIn(DriftUserSettingsRepository settings) async {
  final current = await settings.getSettings();
  await settings
      .saveSettings(current.copyWith(cloudConsentState: ConsentState.accepted));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late EgressRig rig;
  late F2Fixture f;
  late _NoNetwork network;

  setUp(() async {
    rig = EgressRig();
    CloudEgressGate.instance = rig.gate;
    ConsentAuthority.egressFrozen = false;
    network = _NoNetwork();
    f = await F2Fixture.create();
    // The identity evidence of the consent capability is the ACTUAL SDK session
    // (the existing MockClient-backed fake client), injected through the typed
    // seam BEFORE the sign-in whose committed publication issues the capability.
    final sdk = await F2Fixture.liveClient('uid-x');
    f.session.configureConsentSdkClient(() => sdk);
    await f.signIn('uid-x');
  });

  tearDown(() async {
    await f.dispose();
    ConsentAuthority.egressFrozen = false;
  });

  for (final point in _Point.values) {
    for (final transition in _Transition.values) {
      test('enable paused at ${point.name}, then ${transition.name}: stale, '
          'nothing ON, newer scope untouched, no network', () async {
        final db = f.host.current!.database;
        final settings = _PausingSettings(db);
        final service = _service(f, db, settings, rig, network);
        final capability = f.session.captureConsentCapability()!;
        Completer<void>? storeRelease;
        switch (point) {
          case _Point.settingsRead:
            settings.pauseAtRead(1);
          case _Point.storeWrite:
            storeRelease = rig.secure.pauseAfterNextWrite();
          case _Point.localCommit:
            // Held INSIDE the typed transaction, before anything is written.
            settings.pauseAtRead(2);
        }
        final outcome = service
            .enableCloud(
                write: ConsentWrite(
                    capability,
                    const ConsentChoices(
                        cloud: ConsentState.accepted,
                        ai: ConsentState.accepted)))
            .then<Object?>((_) => null, onError: (Object e) => e);
        switch (point) {
          case _Point.settingsRead:
          case _Point.localCommit:
            await settings.reached!.future;
          case _Point.storeWrite:
            await rig.secure.reached!.future;
        }

        // The transition is STARTED, not awaited: awaiting it before releasing
        // the hold would deadlock, because it waits for the bounded operation.
        var transitionDone = false;
        var removed = false;
        var enableSettled = false;
        var enableSettledBeforeRemoval = false;
        unawaited(outcome.then((_) => enableSettled = true));
        final Future<void> transitionFuture;
        switch (transition) {
          case _Transition.signOut:
            transitionFuture = f.session.signOut();
          case _Transition.removeData:
            transitionFuture = f.session.removeDataFromDevice().then((_) {
              removed = true;
              enableSettledBeforeRemoval = enableSettled;
            });
          case _Transition.switchUid:
            transitionFuture = f.signIn('uid-y');
          case _Transition.sameUidReadmission:
            transitionFuture = f.signIn('uid-x');
        }
        unawaited(transitionFuture.whenComplete(() => transitionDone = true));
        // Synchronously invalidated: the held operation's proof is revoked and
        // nothing new can capture an authority or a capability.
        expect(capability.isCurrent, isFalse);
        expect(f.session.captureConsentCapability(), isNull);
        expect(f.session.captureLocalWorkAuthority(), isNull);
        await pumpEventQueue(times: 40);
        expect(transitionDone, isFalse,
            reason: 'the transition waits for the bounded local operation');
        expect(removed, isFalse);

        switch (point) {
          case _Point.settingsRead:
          case _Point.localCommit:
            settings.resume();
          case _Point.storeWrite:
            storeRelease!.complete();
        }
        final error = await outcome;
        await transitionFuture;

        expect(error, isA<StaleAdmissionException>(),
            reason: 'a revoked enable never reports success');
        expect(settings.saved, 0, reason: 'no typed save completed');
        expect(
            (await rig.layers()).where((r) => r.state == EgressState.on),
            isEmpty,
            reason: 'nothing is left ON for the revoked scope');
        expect(await rig.layers('uid-y'), isEmpty);
        expect(await rig.gate.permits(owner: kRigOwner), isFalse);
        expect(network.calls, 0, reason: 'no network inside the local drain');
        expect(ConsentAuthority.egressFrozen, isFalse,
            reason: 'a revoked enable never freezes another scope');
        if (transition == _Transition.switchUid ||
            transition == _Transition.sameUidReadmission) {
          final fresh = DriftUserSettingsRepository(f.host.current!.database);
          final s = await fresh.getSettings();
          expect(s.cloudConsentState, ConsentState.unset,
              reason: 'the newer scope was never asked or written');
          expect(s.aiConsentState, ConsentState.unset);
        }
        if (transition == _Transition.removeData) {
          expect(enableSettledBeforeRemoval, isTrue,
              reason: 'deletion began only after the bounded local work ended');
          expect(await f.artifactsOf('uid-x'), isEmpty);
          expect(await f.flow.revokedUids(), contains('uid-x'));
        }
      });
    }
  }

  test('same uid readmitted while the stale write is paused: the stale enable '
      'settles first, then the new scope enables once and keeps its ON',
      () async {
    final db = f.host.current!.database;
    final service = _service(f, db, _PausingSettings(db), rig, network);
    final authority = f.session.captureLocalWorkAuthority()!;
    final release = rig.secure.pauseAfterNextWrite();
    final stale = service
        .enableCloudForTest(authority: authority, commitLocalOn: () async {})
        .then<Object?>((_) => null, onError: (Object e) => e);
    await rig.secure.reached!.future;
    // Started, not awaited: the readmission waits for the held local operation.
    var readmitted = false;
    final readmission = f.signIn('uid-x').whenComplete(() => readmitted = true);
    expect(authority.isCurrent, isFalse);
    await pumpEventQueue(times: 40);
    expect(readmitted, isFalse);
    release.complete();
    expect(await stale, isA<StaleAdmissionException>());
    await readmission;
    final newDb = f.host.current!.database;
    final newSettings = _PausingSettings(newDb);
    await _service(f, newDb, newSettings, rig, network).enableCloud(
        write: ConsentWrite(
            f.session.captureConsentCapability()!,
            const ConsentChoices(
                cloud: ConsentState.accepted, ai: ConsentState.accepted)));
    expect(newSettings.saved, 1);
    final layers = await rig.layers();
    expect(layers, hasLength(3));
    expect(layers.map((r) => r.state).toSet(), {EgressState.on});
    expect(layers.map((r) => r.transitionGeneration).toSet(), {2});
    expect(await rig.gate.permits(owner: kRigOwner), isTrue);
    expect((await newSettings.getSettings()).cloudConsentState,
        ConsentState.accepted);
    expect(network.calls, 0);
  });

  test('typed enable in the current scope: the choice is saved once and the '
      'gate opens', () async {
    final db = f.host.current!.database;
    final settings = _PausingSettings(db);
    await _service(f, db, settings, rig, network).enableCloud(
        write: ConsentWrite(
            f.session.captureConsentCapability()!,
            const ConsentChoices(
                cloud: ConsentState.accepted, ai: ConsentState.accepted)));
    expect(settings.saved, 1);
    final stored = await settings.getSettings();
    expect(stored.cloudConsentState, ConsentState.accepted);
    expect(stored.aiConsentState, ConsentState.accepted);
    expect((await rig.layers()).map((r) => r.state).toSet(), {EgressState.on});
    expect(await rig.gate.permits(owner: kRigOwner), isTrue);
    expect(ConsentAuthority.egressFrozen, isFalse);
    expect(network.calls, 0);
  });

  test('a logout between the final guard and COMMIT: the choice is honestly '
      'persisted, the enable cannot report success and the durable egress '
      'stays denied', () async {
    final db = f.host.current!.database;
    Future<void>? logout;
    final settings = _PausingSettings(db,
        afterConsentFinalGuard: () => logout = f.session.signOut());
    final capability = f.session.captureConsentCapability()!;
    final error = await _service(f, db, settings, rig, network)
        .enableCloud(
            write: ConsentWrite(
                capability,
                const ConsentChoices(
                    cloud: ConsentState.accepted, ai: ConsentState.accepted)))
        .then<Object?>((_) => null, onError: (Object e) => e);
    await logout;
    expect(error, isA<StaleAdmissionException>(),
        reason: 'a now-stale enable never reports success');
    expect(settings.saved, 1, reason: 'the authorized COMMIT landed');
    expect((await rig.layers()).where((r) => r.state == EgressState.on),
        isEmpty,
        reason: 'the gate ON was compensated: durable egress is denied');
    expect(await rig.gate.permits(owner: kRigOwner), isFalse);
    expect(ConsentAuthority.egressFrozen, isFalse);
    expect(network.calls, 0);
    // Readmitted later, the legitimate local choice is still there.
    await f.signIn('uid-x');
    final stored =
        await DriftUserSettingsRepository(f.host.current!.database)
            .getSettings();
    expect(stored.cloudConsentState, ConsentState.accepted);
    expect(await rig.gate.permits(owner: kRigOwner), isFalse,
        reason: 'accepted settings alone never reopen a denied gate');
  });

  test('current scope: one explicit enable saves once and opens the gate',
      () async {
    final db = f.host.current!.database;
    final settings = _PausingSettings(db);
    var commits = 0;
    await _service(f, db, settings, rig, network).enableCloudForTest(
        authority: f.session.captureLocalWorkAuthority()!,
        commitLocalOn: () async {
          commits++;
          await _acceptIn(settings);
        });
    expect(commits, 1);
    expect((await rig.layers()).map((r) => r.state).toSet(), {EgressState.on});
    expect(await rig.gate.permits(owner: kRigOwner), isTrue);
    expect((await settings.getSettings()).cloudConsentState,
        ConsentState.accepted);
    expect(ConsentAuthority.egressFrozen, isFalse);
    expect(network.calls, 0);
  });

  test('two same-scope enables with distinct commits are serialized: both '
      'run, in order, none is faked complete', () async {
    final db = f.host.current!.database;
    final service = _service(f, db, _PausingSettings(db), rig, network);
    final hold = Completer<void>();
    final order = <String>[];
    final a = service.enableCloudForTest(
        authority: f.session.captureLocalWorkAuthority()!,
        commitLocalOn: () async {
          order.add('a-start');
          await hold.future;
          order.add('a-end');
        });
    var bDone = false;
    final b = service
        .enableCloudForTest(
            authority: f.session.captureLocalWorkAuthority()!,
            commitLocalOn: () async => order.add('b'))
        .then((_) => bDone = true);
    await pumpEventQueue(times: 40);
    expect(order, ['a-start']);
    expect(bDone, isFalse, reason: 'b is not completed by a');
    hold.complete();
    await a;
    await b;
    expect(order, ['a-start', 'a-end', 'b']);
    expect((await rig.layers()).map((r) => r.transitionGeneration).toSet(),
        {2});
  });

  test('current scope, commit fails: the gate is restricted again and the '
      'original error is reported', () async {
    final db = f.host.current!.database;
    await expectLater(
        _service(f, db, _PausingSettings(db), rig, network).enableCloudForTest(
            authority: f.session.captureLocalWorkAuthority()!,
            commitLocalOn: () async => throw StateError('disk')),
        throwsA(isA<StateError>()));
    expect((await rig.layers()).map((r) => r.state).toSet(), {EgressState.off});
    expect(await rig.gate.permits(owner: kRigOwner), isFalse);
    expect(ConsentAuthority.egressFrozen, isFalse);
  });

  test('current scope, commit fails AND the restriction cannot be written: '
      'reported as uncertain and the scope fails closed', () async {
    final db = f.host.current!.database;
    await expectLater(
        _service(f, db, _PausingSettings(db), rig, network).enableCloudForTest(
            authority: f.session.captureLocalWorkAuthority()!,
            commitLocalOn: () async {
              rig.failAllWrites();
              throw StateError('disk');
            }),
        throwsA(isA<EgressWriteFailedException>()));
    expect(ConsentAuthority.egressFrozen, isTrue,
        reason: 'denial is retained, never cleared on uncertainty');
    expect(await rig.gate.permits(owner: kRigOwner), isFalse,
        reason: 'frozen: the still-ON record admits nothing');
  });
}
