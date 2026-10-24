import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/core/session/admission_authority.dart';

import '../../harness/paused_egress_support.dart';

// Task 01 — an explicit enable whose scope is revoked while its store write is
// in flight. The write can land ON after the revocation, so the gate judges
// freshness inside its lock AFTER the write and restricts what it wrote, store
// by store (the merged winner alone can hide an ON behind an older OFF).

void main() {
  test('stale AFTER the store write landed ON: OFF in every store, Stale',
      () async {
    final r = EgressRig();
    var live = true;
    final release = r.secure.pauseAfterNextWrite();
    final pending = r.gate
        .enable(owner: kRigOwner, reservedVersion: 2, isCurrent: () => live);
    final check =
        expectLater(pending, throwsA(isA<StaleAdmissionException>()));
    await r.secure.reached!.future;
    expect(r.secure.value, isNotNull, reason: 'the ON write already landed');
    live = false; // logout / removal / switch / readmission at a new epoch
    release.complete();
    await check;
    final layers = await r.layers();
    expect(layers, hasLength(3));
    expect(layers.map((e) => e.state).toSet(), {EgressState.off});
    expect(layers.map((e) => e.transitionGeneration).toSet(), {1});
    expect(await r.gate.permits(owner: kRigOwner), isFalse);
  });

  test('older OFF in one store must not mask the just-written ON in the '
      'others: compensation judges every store', () async {
    final r = EgressRig();
    r.file.value = rigEnvelope(rigRecord(EgressState.off, 1));
    r.file.failNextWrite = true; // the ON write misses the store holding OFF
    var live = true;
    final release = r.secure.pauseAfterNextWrite();
    final pending = r.gate
        .enable(owner: kRigOwner, reservedVersion: 2, isCurrent: () => live);
    final check =
        expectLater(pending, throwsA(isA<StaleAdmissionException>()));
    await r.secure.reached!.future;
    live = false;
    release.complete();
    await check;
    expect(r.native.stored?.state, EgressState.off,
        reason: 'the native ON must not survive behind the older OFF');
    expect(r.native.stored?.transitionGeneration, 2);
    final layers = await r.layers();
    expect(layers.map((e) => e.state).toSet(), {EgressState.off});
    expect(layers.map((e) => e.transitionGeneration).toSet(), {2});
  });

  test('an unreadable store beside a visible NEWER same-owner ON: nothing is '
      'downgraded', () async {
    final r = EgressRig();
    final newer = rigRecord(EgressState.on, 3, 5);
    r.file.value = rigEnvelope(newer);
    r.native.stored = newer;
    r.secure.failReads = true;
    expect(await r.gate.restrictWrittenOn(rigRecord(EgressState.on, 2, 2)),
        isTrue);
    expect(r.file.value, rigEnvelope(newer));
    expect(r.file.writes, 0);
    expect(r.secure.writes, 0);
    expect(r.native.stored, newer);
    expect(r.native.writes, 0);
  });

  test('compensation that cannot be written is never a normal outcome',
      () async {
    final r = EgressRig();
    var live = true;
    final release = r.secure.pauseAfterNextWrite();
    final pending = r.gate
        .enable(owner: kRigOwner, reservedVersion: 2, isCurrent: () => live);
    final check =
        expectLater(pending, throwsA(isA<EgressWriteFailedException>()));
    await r.secure.reached!.future;
    live = false;
    r.failAllWrites();
    release.complete();
    await check;
    expect(await r.gate.restrictWrittenOn(rigRecord(EgressState.on, 1, 2)),
        isFalse,
        reason: 'all writes failing is reported, never claimed clean');
  });

  test('a newer legitimate enable queued behind the stale one survives it',
      () async {
    final r = EgressRig();
    var live = true;
    final release = r.secure.pauseAfterNextWrite();
    final stale = r.gate
        .enable(owner: kRigOwner, reservedVersion: 2, isCurrent: () => live);
    final check = expectLater(stale, throwsA(isA<StaleAdmissionException>()));
    await r.secure.reached!.future;
    live = false;
    final newer = r.gate.enable(owner: kRigOwner, reservedVersion: 3);
    release.complete();
    await check;
    final rec = await newer;
    expect(rec.state, EgressState.on);
    expect(rec.transitionGeneration, 2);
    final layers = await r.layers();
    expect(layers, hasLength(3));
    expect(layers.toSet(), {rec});
    expect(await r.gate.permits(owner: kRigOwner), isTrue);
  });

  test('late compensation for an older enable never touches a newer one',
      () async {
    final r = EgressRig();
    final first = await r.gate.enable(owner: kRigOwner, reservedVersion: 2);
    final second = await r.gate.enable(owner: kRigOwner, reservedVersion: 3);
    expect(await r.gate.restrictWrittenOn(first), isTrue);
    expect((await r.layers()).toSet(), {second});
  });

  test('stale before the write: nothing is written anywhere', () async {
    final r = EgressRig();
    var calls = 0;
    await expectLater(
        r.gate.enable(
            owner: kRigOwner,
            reservedVersion: 2,
            isCurrent: () => ++calls < 2),
        throwsA(isA<StaleAdmissionException>()));
    expect(r.secure.writes + r.file.writes + r.native.writes, 0);
    expect(r.native.stored, isNull);
  });
}
