import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/core/session/admission_authority.dart';

import '../../harness/paused_egress_support.dart';

// N-CR-1 / N-CR-2 at the gate: the transition helpers judge currency inside the
// serialized mutation boundary, never overwrite a successor's newer record, and
// the read-back reports each admitting runtime separately.

void main() {
  late EgressRig rig;
  // ignore: prefer_final_locals
  late CloudEgressGate gate;

  setUp(() {
    rig = EgressRig();
    gate = rig.gate;
  });

  Future<List<CloudEgressRecord>> layers() => rig.layers();

  group('currency inside the lock', () {
    test('a stale beginDisabling writes nothing', () async {
      const live = false;
      await expectLater(
          gate.beginDisabling(
              owner: kRigOwner, reservedVersion: 2, isCurrent: () => live),
          throwsA(isA<StaleAdmissionException>()));
      expect(await layers(), isEmpty);
    });

    test('a beginDisabling that goes stale while waiting for the lock '
        'writes nothing', () async {
      var live = true;
      final hold = rig.secure.pauseAfterNextWrite();
      final first = gate.writeRecord(rigRecord(EgressState.on, 1, 1));
      await rig.secure.reached!.future;
      final second = gate.beginDisabling(
          owner: kRigOwner, reservedVersion: 2, isCurrent: () => live);
      live = false; // revoked while queued behind the first write
      hold.complete();
      await first;
      await expectLater(second, throwsA(isA<StaleAdmissionException>()));
      expect((await layers()).every((r) => r.state == EgressState.on), isTrue);
    });

    test('a stale commitOff writes no OFF and a stale rewriteDisabling no '
        'DISABLING', () async {
      final freeze = await gate.beginDisabling(
          owner: kRigOwner, reservedVersion: 2);
      await expectLater(
          gate.commitOff(freeze, isCurrent: () => false),
          throwsA(isA<StaleAdmissionException>()));
      expect((await layers()).every((r) => r.state == EgressState.disabling),
          isTrue);
      await rig.gate.commitOff(freeze);
      await expectLater(
          gate.rewriteDisabling(freeze, isCurrent: () => false),
          throwsA(isA<StaleAdmissionException>()));
      expect((await layers()).every((r) => r.state == EgressState.off), isTrue);
    });
  });

  group('a stale completion never overwrites successor state', () {
    test('commitOff refuses to replace a newer generation in any store',
        () async {
      final freeze = await gate.beginDisabling(
          owner: kRigOwner, reservedVersion: 2); // generation 1
      // A successor enable then wrote ON at the next generation everywhere.
      final successor = rigRecord(EgressState.on, freeze.transitionGeneration + 1, 3);
      await gate.writeRecord(successor);
      expect(await gate.commitOff(freeze), isFalse);
      expect(await layers(), everyElement(successor),
          reason: 'the successor ON is intact in every store');
    });

    test('a newer generation held by the native layer alone also blocks the '
        'stale OFF', () async {
      final freeze = await gate.beginDisabling(
          owner: kRigOwner, reservedVersion: 2);
      rig.native.stored =
          rigRecord(EgressState.on, freeze.transitionGeneration + 1, 3);
      expect(await gate.commitOff(freeze), isFalse);
      expect(rig.secure.value, isNot(contains('"state":"OFF"')));
      expect(rig.file.value, isNot(contains('"state":"OFF"')));
    });

    test('the current, unsuperseded commitOff still lands', () async {
      final freeze = await gate.beginDisabling(
          owner: kRigOwner, reservedVersion: 2);
      expect(await gate.commitOff(freeze, isCurrent: () => true), isTrue);
      expect((await layers()).every((r) => r.state == EgressState.off), isTrue);
    });
  });

  group('verifyRestriction reads each runtime back', () {
    test('everything held: verified', () async {
      final freeze = await gate.beginDisabling(
          owner: kRigOwner, reservedVersion: 2);
      final r = await gate.verifyRestriction(freeze);
      expect(r.dart, isTrue);
      expect(r.native, isTrue);
      expect(r.verified, isTrue);
    });

    test('native failed to take the record: Dart true, native false, not '
        'verified', () async {
      rig.native.failWrites = true;
      final freeze = await gate.beginDisabling(
          owner: kRigOwner, reservedVersion: 2);
      final r = await gate.verifyRestriction(freeze);
      expect(r.dart, isTrue);
      expect(r.native, isFalse);
      expect(r.verified, isFalse);
    });

    test('a native ON (not restrictive) is not verified', () async {
      rig.native.failWrites = true;
      rig.native.stored = rigRecord(EgressState.on, 1, 1);
      final freeze = await gate.beginDisabling(
          owner: kRigOwner, reservedVersion: 2);
      expect((await gate.verifyRestriction(freeze)).native, isFalse);
    });

    test('both Dart stores failed: Dart false even though native holds it',
        () async {
      rig.secure.failWrites = true;
      rig.file.failWrites = true;
      final freeze = await gate.beginDisabling(
          owner: kRigOwner, reservedVersion: 2);
      final r = await gate.verifyRestriction(freeze);
      expect(r.dart, isFalse);
      expect(r.native, isTrue);
      expect(r.verified, isFalse);
    });

    test('one Dart store suffices (the restrictive merge)', () async {
      rig.file.failWrites = true;
      final freeze = await gate.beginDisabling(
          owner: kRigOwner, reservedVersion: 2);
      expect((await gate.verifyRestriction(freeze)).verified, isTrue);
    });

    test('an older restrictive record than the frozen generation is not '
        'enough', () async {
      final freeze = await gate.beginDisabling(
          owner: kRigOwner, reservedVersion: 2);
      final newer = DisableFreeze(
          owner: kRigOwner,
          transitionGeneration: freeze.transitionGeneration + 5,
          reservedVersion: 9);
      final r = await gate.verifyRestriction(newer);
      expect(r.verified, isFalse);
    });

    test('no native layer: only the Dart runtime is judged', () async {
      final noNative = CloudEgressGate(
        store: CloudEgressStore.forTesting(
            secure: rig.secure, file: rig.file),
        activeOwner: () async => kRigOwner,
        resolved: true,
        nativeInflight: (_) async => (count: 0, latestDeadline: null),
      );
      final freeze = await noNative.beginDisabling(
          owner: kRigOwner, reservedVersion: 2);
      final r = await noNative.verifyRestriction(freeze);
      expect(r.native, isNull);
      expect(r.verified, isTrue);
    });
  });
}
