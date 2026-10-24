import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/core/privacy/consent_authority.dart';
import 'package:money_companion/core/session/admission_authority.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';

import '../../harness/consent_session_support.dart';
import '../../harness/paused_egress_support.dart';
import 'f2_fixture.dart';

// N2 first subunit: actual AppSession/SDK identity and real per-UID Drift.
// MethodChannel replies simulate ONLY the native boundary, not native execution.
//
// Harness note: a sign-in opens a real encrypted SQLite replica, so the time it
// needs to reach the native publication is real I/O, not a number of event-loop
// turns. The first version waited a fixed `pumpEventQueue(times: 40)` and asserted
// the publication call right after it, which could fail before the code under
// test ran. Positive waits now poll for the event with a real-time bound; the
// negative assertions (still held, still closed) are unchanged.

/// What the simulated native publication reply gets wrong, if anything.
enum _Fault { none, otherOwner, layerNotVerified, layersDisagree, noReceipt }

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('money_companion/native_capture');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late F2Fixture f;
  late EgressRig rig;
  late CloudEgressGate previousGate;
  late List<MethodCall> calls;
  late List<Completer<void>> releases;
  Completer<void>? publicationHold;
  Completer<void>? fenceHold;
  Completer<void>? finishHold;
  var incompleteFence = false;
  var nativeGeneration = 7;
  var fault = _Fault.none;

  Map<String, Object?> publication(Map<Object?, Object?> args) => {
    'contractVersion': 1, 'operation': 'publishRestrictive', 'status': 'done',
    'owner': {
      'uid': fault == _Fault.otherOwner ? 'uid-other' : args['uid'],
      'uidHash': List.filled(64, 'a').join(), 'generation': nativeGeneration,
    },
    'ownerGeneration': nativeGeneration, 'ownerEpoch': args['expectedEpoch'],
    'barrier': [for (final layer in ['file', 'keychain']) {'layer': layer, 'outcome': 'absent'}],
    'egress': [for (final layer in ['file', 'keychain']) {
      'layer': layer,
      'outcome': fault == _Fault.layerNotVerified && layer == 'keychain' ? 'writeFailed' : 'verified',
      'state': 'OFF',
      'transitionGeneration': fault == _Fault.layersDisagree && layer == 'keychain' ? 4 : 3,
      'reservedVersion': args['version'],
      'ownerGeneration': nativeGeneration, 'ownerEpoch': args['expectedEpoch'],
    }],
  };

  Map<String, Object?> revoked(Map<Object?, Object?> args) => {
    'contractVersion': 1, 'operation': 'revoke', 'status': incompleteFence ? 'incomplete' : 'done',
    for (final key in ['operationId', 'transitionGeneration', 'reservedVersion', 'ownerGeneration', 'ownerEpoch']) key: args[key],
    'barrier': [for (final layer in ['file', 'keychain']) {'layer': layer, 'outcome': 'absent'}],
    'egress': [for (final layer in ['file', 'keychain']) {
      'layer': layer, 'outcome': incompleteFence ? 'writeFailed' : 'verified', 'state': 'OFF',
      for (final key in ['operationId', 'transitionGeneration', 'reservedVersion', 'ownerGeneration', 'ownerEpoch']) key: args[key],
    }],
  };

  Future<RestrictiveCaptureOwnerReceipt?> publish(String uid, AdmissionAuthority authority) async {
    // The callback receives the actual committed admission authority, including
    // first onboarding. No status-only or forTest authority is constructed.
    expect(authority.uid, uid);
    expect(authority.isCurrent, isTrue);
    final db = f.host.current!.database;
    expect(f.host.activeUid, uid);
    final owner = await db.customSelect('SELECT owner_uid FROM replica_meta WHERE id = 1;').getSingle();
    expect(owner.read<String>('owner_uid'), uid);
    final settings = await DriftUserSettingsRepository(db).getSettings();
    final epoch = await NativeCaptureBridge.captureOwnerEpoch();
    return NativeCaptureBridge.publishRestrictiveCaptureOwner(
      uid: uid, version: settings.consentVersion, expectedEpoch: epoch);
  }

  List<MethodCall> publications() => calls.where((c) => c.method == 'publishRestrictiveCaptureOwner').toList();
  List<MethodCall> finishes() => calls.where((c) => c.method == 'finishCloudEgressEnable').toList();
  List<MethodCall> fences() => calls.where((c) => c.method == 'revokeCaptureAuthorizationLifetime').toList();
  Future<Object?> observe(Future<Object?> future) => future.then<Object?>((_) => null, onError: (Object e) => e);
  Completer<void> hold() {
    final release = Completer<void>();
    releases.add(release);
    return release;
  }

  /// Polls (real time, bounded) until [condition] holds.
  Future<void> until(bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) fail('the awaited native call never happened');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  setUp(() async {
    previousGate = CloudEgressGate.instance;
    rig = EgressRig();
    CloudEgressGate.instance = rig.gate;
    ConsentAuthority.egressFrozen = false;
    f = await F2Fixture.create();
    calls = [];
    releases = [];
    publicationHold = null;
    fenceHold = null;
    finishHold = null;
    incompleteFence = false;
    nativeGeneration = 7;
    fault = _Fault.none;
    NativeCaptureBridge.debugTreatHostAsNative = true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'captureOwnerEpoch') return 2;
      final args = Map<Object?, Object?>.from(call.arguments as Map);
      if (call.method == 'publishRestrictiveCaptureOwner') {
        final reply = publication(args); // capture outgoing evidence before hold
        await publicationHold?.future;
        return fault == _Fault.noReceipt ? null : reply;
      }
      if (call.method == 'finishCloudEgressEnable') {
        await finishHold?.future;
        return {
          'contractVersion': 1, 'operation': 'complete', 'status': 'incomplete',
          for (final key in ['operationId', 'transitionGeneration', 'reservedVersion', 'ownerGeneration', 'ownerEpoch']) key: args[key],
          'barrier': [for (final layer in ['file', 'keychain']) {'layer': layer, 'outcome': 'absent'}],
          'egress': const [],
        };
      }
      if (call.method == 'revokeCaptureAuthorizationLifetime') {
        await fenceHold?.future;
        return revoked(args);
      }
      throw StateError('unexpected native operation ${call.method}');
    });
    f.session.configureCaptureOwnerPublish(publish);
  });

  tearDown(() async {
    for (final release in releases) {
      if (!release.isCompleted) release.complete();
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

  test('first committed onboarding awaits restrictive publication receipt', () async {
    publicationHold = hold();
    var settled = false;
    final pending = observe(freshSignIn(f, 'uid-x'));
    unawaited(pending.then((_) => settled = true));
    try {
      await until(() => publications().isNotEmpty);
      await pumpEventQueue(times: 40);
      expect(publications(), hasLength(1));
      expect(f.session.captureLocalWorkAuthority(), isNull);
      expect(settled, isFalse, reason: 'void/unawaited publication is not a receipt');
    } finally {
      publicationHold!.complete();
      await pending;
    }
    // The first-onboarding permission is the consent-only capability; the
    // publication gave no ordinary local-work authority to the onboarding scope.
    expect(f.session.captureConsentCapability(), isNotNull);
    expect(f.session.captureLocalWorkAuthority(), isNull);
    expect(await f.session.nativeLifecycleSettled(), NativeLifecycleOutcome.confirmed);
  });

  test('loss before publication reply denies Dart and fences returned outgoing lifetime', () async {
    publicationHold = hold();
    final pending = observe(freshSignIn(f, 'uid-x'));
    try {
      await until(() => publications().isNotEmpty);
      expect(publications(), hasLength(1));
      final epoch = rig.gate.epoch;
      f.session.markSessionInvalid();
      expect(f.session.captureConsentCapability(), isNull);
      expect(rig.gate.epoch, greaterThan(epoch), reason: 'Dart denial starts synchronously');
      expect(fences(), isEmpty, reason: 'the lifetime to fence is not known until the reply');
      publicationHold!.complete();
      await pending;
      await until(() => fences().isNotEmpty);
      await pumpEventQueue(times: 40);
      expect(fences(), hasLength(1));
      final args = Map<Object?, Object?>.from(fences().single.arguments as Map);
      expect(args['ownerUid'], 'uid-x');
      expect(args['ownerGeneration'], 7);
      expect(args['ownerEpoch'], 2);
      expect(args['transitionGeneration'], 3);
      expect(args['operationId'], matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(await f.session.nativeLifecycleSettled(), NativeLifecycleOutcome.confirmed);
    } finally {
      if (!publicationHold!.isCompleted) publicationHold!.complete();
      await pending;
    }
  });

  for (final incomplete in [false, true]) {
    test(incomplete
        ? 'incomplete native fence keeps next publication closed'
        : 'new publication waits for exact outgoing native fence settlement', () async {
      await freshSignIn(f, 'uid-x');
      await until(() => publications().isNotEmpty);
      expect(publications(), hasLength(1));
      // A durable ON record makes the Dart denial observable (an empty store is
      // denied anyway).
      await rig.gate.enable(owner: 'uid-x', reservedVersion: 1);
      expect(await rig.gate.permits(owner: 'uid-x'), isTrue);
      fenceHold = hold();
      incompleteFence = incomplete;
      final epoch = rig.gate.epoch;
      f.session.markSessionInvalid();
      f.session.markSessionInvalid(); // repeated events must not mint a second fence
      expect(rig.gate.epoch, greaterThan(epoch));
      expect(await rig.gate.permits(owner: 'uid-x'), isFalse,
          reason: 'Dart egress is denied synchronously at the loss');
      await until(() => fences().isNotEmpty);
      await pumpEventQueue(times: 30);
      expect(fences(), hasLength(1));
      final oldArgs = Map<Object?, Object?>.from(fences().single.arguments as Map);
      nativeGeneration = 8;
      final next = observe(freshSignIn(f, 'uid-x'));
      try {
        await pumpEventQueue(times: 30);
        expect(publications(), hasLength(1), reason: 'old fence reply still pending');
        expect(f.session.captureLocalWorkAuthority(), isNull);
        expect(await rig.gate.permits(owner: 'uid-x'), isFalse);
        fenceHold!.complete();
        expect(oldArgs['ownerGeneration'], 7);
        expect(oldArgs['ownerEpoch'], 2);
        if (incomplete) {
          await next.timeout(const Duration(seconds: 3));
          await pumpEventQueue(times: 40);
          expect(publications(), hasLength(1));
          expect(fences(), hasLength(1), reason: 'no automatic retry of the failed fence');
          expect(await rig.gate.permits(owner: 'uid-x'), isFalse,
              reason: 'an unconfirmed fence leaves Dart denied');
          expect(await f.session.nativeLifecycleSettled(), NativeLifecycleOutcome.incomplete);
        } else {
          await next.timeout(const Duration(seconds: 3));
          expect(publications(), hasLength(2));
          expect(fences(), hasLength(1));
          expect(await rig.gate.permits(owner: 'uid-x'), isTrue,
              reason: 'a confirmed fence and a verified publication release the denial');
          expect(await f.session.nativeLifecycleSettled(), NativeLifecycleOutcome.confirmed);
        }
      } finally {
        if (!fenceHold!.isCompleted) fenceHold!.complete();
        // A failed fence must return a bounded incomplete outcome, not hang.
        await next.timeout(const Duration(seconds: 3));
      }
    });
  }

  for (final bad in [
    _Fault.otherOwner,
    _Fault.layerNotVerified,
    _Fault.layersDisagree,
    _Fault.noReceipt,
  ]) {
    test('a $bad publication is no receipt: nothing is cached, nothing is fenced', () async {
      fault = bad;
      await freshSignIn(f, 'uid-x').timeout(const Duration(seconds: 5));
      await until(() => publications().isNotEmpty);
      expect(publications(), hasLength(1));
      expect(await f.session.nativeLifecycleSettled(), NativeLifecycleOutcome.incomplete);
      // The consent-only permission of first onboarding does not depend on the
      // native publication.
      expect(f.session.captureConsentCapability(), isNotNull);
      f.session.markSessionInvalid();
      expect(await f.session.nativeLifecycleSettled(), NativeLifecycleOutcome.incomplete);
      await pumpEventQueue(times: 30);
      expect(fences(), isEmpty, reason: 'no fence is fabricated from an unverified reply');
    });
  }

  test('an idempotent reconcile of the same account neither republishes nor fences', () async {
    final client = await F2Fixture.liveClient('uid-x');
    await freshSignIn(f, 'uid-x', client: client);
    await until(() => publications().isNotEmpty);
    expect(publications(), hasLength(1));
    await f.session.revalidateSupabaseSessionOnResume(client);
    await pumpEventQueue(times: 40);
    expect(publications(), hasLength(1), reason: 'would re-publish OFF over a confirmed ON');
    expect(fences(), isEmpty);
    expect(await f.session.nativeLifecycleSettled(), NativeLifecycleOutcome.confirmed);
  });

  // Astra A1/A2: the Dart side retires exactly the PUBLICATION binding (generation
  // g); native retirement must cover a later enable g+1 of that lifecycle (proven
  // by RunnerTests), so Dart must never widen or rebind the request.
  test('retirement request is the exact publication binding, once, even after an enable', () async {
    await freshSignIn(f, 'uid-x');
    await until(() => publications().isNotEmpty);
    await rig.gate.enable(owner: 'uid-x', reservedVersion: 2); // an enable after publication
    f.session.markSessionInvalid();
    f.session.markSessionInvalid();
    await until(() => fences().isNotEmpty);
    await pumpEventQueue(times: 30);
    expect(fences(), hasLength(1), reason: 'duplicate loss joins one retirement');
    final args = Map<Object?, Object?>.from(fences().single.arguments as Map);
    expect(args['transitionGeneration'], 3);
    expect(args['ownerGeneration'], 7);
    expect(args['ownerEpoch'], 2);
    expect(await f.session.nativeLifecycleSettled(), NativeLifecycleOutcome.confirmed);
  });

  test('retirement timeout/incomplete: same-UID and different-UID admission publish nothing', () async {
    await freshSignIn(f, 'uid-x');
    await until(() => publications().isNotEmpty);
    incompleteFence = true;
    f.session.markSessionInvalid();
    await until(() => fences().isNotEmpty);
    expect(await f.session.nativeLifecycleSettled(), NativeLifecycleOutcome.incomplete);
    await observe(freshSignIn(f, 'uid-x')).timeout(const Duration(seconds: 5));
    await observe(freshSignIn(f, 'uid-y')).timeout(const Duration(seconds: 5));
    await pumpEventQueue(times: 40);
    expect(publications(), hasLength(1), reason: 'no replacement publication after an unconfirmed fence');
    expect(fences(), hasLength(1));
    expect(await f.session.nativeLifecycleSettled(), NativeLifecycleOutcome.incomplete);
  });

  // ── N-RT (Astra R6 unit 6 / R45 R3) ───────────────────────────────────────
  // Dart-side ordering only; the native serialization itself is proven (when the
  // isolated harness is approved) by RunnerTests, not here.

  CloudEgressEnableBinding enableBinding() => const CloudEgressEnableBinding(
      operationId: 'abcdefabcdefabcdefabcdefabcdefab',
      transitionGeneration: 4, reservedVersion: 5, ownerGeneration: 7, ownerEpoch: 2);

  for (final finishFirst in [true, false]) {
    for (final successor in ['uid-x', 'uid-y']) {
      test('a queued native finish and logout (${finishFirst ? 'finish first' : 'logout first'}), '
          'then a ${successor == 'uid-x' ? 'same' : 'different'}-UID readmission: one retirement of '
          'the publication binding, the successor publishes only after it', () async {
        await freshSignIn(f, 'uid-x');
        await until(() => publications().isNotEmpty);
        finishHold = hold();
        fenceHold = hold();
        Future<Object?> queueFinish() => observe(NativeCaptureBridge.finishCloudEgressEnable(
            ownerUid: 'uid-x', binding: enableBinding(), abandon: false));
        late Future<Object?> finish;
        if (finishFirst) {
          finish = queueFinish();
          await until(() => finishes().isNotEmpty);
          f.session.markSessionInvalid();
        } else {
          f.session.markSessionInvalid();
          await until(() => fences().isNotEmpty);
          finish = queueFinish();
          await until(() => finishes().isNotEmpty);
        }
        await until(() => fences().isNotEmpty);
        nativeGeneration = 8;
        final next = observe(freshSignIn(f, successor));
        await pumpEventQueue(times: 40);
        expect(publications(), hasLength(1), reason: 'the retirement is still outstanding');
        expect(fences(), hasLength(1));
        finishHold!.complete();
        fenceHold!.complete();
        await finish;
        await next.timeout(const Duration(seconds: 10));
        expect(fences(), hasLength(1), reason: 'the queued finish never mints a second retirement');
        final args = Map<Object?, Object?>.from(fences().single.arguments as Map);
        expect(args['ownerUid'], 'uid-x');
        expect(args['ownerGeneration'], 7, reason: 'the publication lifetime, not the successor');
        expect(args['ownerEpoch'], 2);
        expect(args['transitionGeneration'], 3);
        expect(publications(), hasLength(2));
        final order = [for (final c in calls) c.method];
        expect(order.lastIndexOf('revokeCaptureAuthorizationLifetime'),
            lessThan(order.lastIndexOf('publishRestrictiveCaptureOwner')));
        expect(await f.session.nativeLifecycleSettled(), NativeLifecycleOutcome.confirmed);
      });
    }
  }

  for (final successor in ['uid-x', 'uid-y']) {
    test('a late publication reply after loss and a ${successor == 'uid-x' ? 'same' : 'different'}-UID '
        'readmission: the returned lifetime is retired once, the successor publishes after it', () async {
      publicationHold = hold();
      final first = observe(freshSignIn(f, 'uid-x'));
      await until(() => publications().isNotEmpty);
      final firstReply = publicationHold!;
      publicationHold = null;
      f.session.markSessionInvalid();
      nativeGeneration = 8;
      final next = observe(freshSignIn(f, successor));
      await pumpEventQueue(times: 40);
      expect(publications(), hasLength(1), reason: 'the first reply is still outstanding');
      expect(fences(), isEmpty, reason: 'nothing to retire until the reply names the lifetime');
      firstReply.complete();
      await first;
      await next.timeout(const Duration(seconds: 10));
      expect(fences(), hasLength(1));
      final args = Map<Object?, Object?>.from(fences().single.arguments as Map);
      expect(args['ownerUid'], 'uid-x');
      expect(args['ownerGeneration'], 7);
      expect(publications(), hasLength(2));
      final order = [for (final c in calls) c.method];
      expect(order.lastIndexOf('revokeCaptureAuthorizationLifetime'),
          lessThan(order.lastIndexOf('publishRestrictiveCaptureOwner')));
    });
  }

  for (final successor in ['uid-x', 'uid-y']) {
    test('a retirement that never answers: the ${successor == 'uid-x' ? 'same' : 'different'}-UID '
        'successor publishes nothing and nothing reports completion', () async {
      await freshSignIn(f, 'uid-x');
      await until(() => publications().isNotEmpty);
      fenceHold = hold(); // never released inside the bound below
      f.session.markSessionInvalid();
      await until(() => fences().isNotEmpty);
      var settled = false;
      final next = observe(freshSignIn(f, successor));
      unawaited(next.then((_) => settled = true));
      await Future<void>.delayed(const Duration(seconds: 2));
      await pumpEventQueue(times: 40);
      expect(publications(), hasLength(1), reason: 'a timeout never authorizes a replacement publication');
      expect(fences(), hasLength(1), reason: 'no retry of the unanswered retirement');
      expect(f.session.captureLocalWorkAuthority(), isNull);
      var outcomeKnown = false;
      unawaited(f.session.nativeLifecycleSettled().then((_) => outcomeKnown = true));
      await pumpEventQueue(times: 20);
      expect(outcomeKnown, isFalse, reason: 'durable completion is not reported while it is unanswered');
      fenceHold!.complete();
      await next.timeout(const Duration(seconds: 10));
      expect(settled, isTrue);
    });
  }

  test('removal versus an outstanding consent settlement: retirement does not wait on it and '
      'does not create a drain cycle; removal completes once the settlement ends', () async {
    await freshSignIn(f, 'uid-x');
    await until(() => publications().isNotEmpty);
    final capability = f.session.captureConsentCapability()!;
    final settlement = Completer<void>();
    final op = observe(f.session.runConsentLocalOperation(capability, () => settlement.future));
    var removed = false;
    final removal = observe(f.session.removeDataFromDevice().then((_) => removed = true));
    await until(() => fences().isNotEmpty);
    await pumpEventQueue(times: 40);
    expect(fences(), hasLength(1), reason: 'the retirement runs while the settlement is outstanding');
    expect(removed, isFalse, reason: 'removal waits for the outstanding consent settlement');
    settlement.complete();
    await op;
    await removal.timeout(const Duration(seconds: 10));
    expect(removed, isTrue);
    expect(fences(), hasLength(1), reason: 'no second retirement from the drain');
    expect(publications(), hasLength(1));
    expect(await f.session.nativeLifecycleSettled(), NativeLifecycleOutcome.confirmed);
  });
}
