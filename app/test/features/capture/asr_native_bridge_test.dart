import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';

/// ASR v7.2 WP6: the Dart half of the native evidence lane — strict parsing of
/// the new reply fields and the cause appended before each new native write.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const id = '0123456789abcdef0123456789abcdef';
  Map<String, Object?> evidence() => {
        'evidenceId': id,
        'ownerGeneration': 3,
        'ownerEpoch': 1,
        'sessionLifecycle': 7,
      };
  List<Map<String, Object?>> layers() => [
        {'layer': 'file', 'outcome': 'absent'},
        {'layer': 'keychain', 'outcome': 'absent'},
      ];
  Map<String, Object?> reply([Map<String, Object?> extra = const {}]) => {
        'contractVersion': 1,
        'operation': 'revoke',
        'status': 'done',
        'barrier': layers(),
        'egress': layers(),
        ...extra,
      };

  group('CloudEgressEnableResult', () {
    test('accepts the counter and the evidence', () {
      final r = CloudEgressEnableResult.tryParse(
          reply({'mutationCounter': 12, 'expiryEvidence': evidence()}))!;
      expect(r.mutationCounter, 12);
      expect(
          r.expiryEvidence,
          const NativeExpiryEvidence(
              evidenceId: id,
              ownerGeneration: 3,
              ownerEpoch: 1,
              sessionLifecycle: 7));
      expect(CloudEgressEnableResult.tryParse(reply())!.expiryEvidence, isNull);
    });

    test('rejects a malformed counter or evidence', () {
      expect(CloudEgressEnableResult.tryParse(reply({'mutationCounter': -1})),
          isNull);
      expect(CloudEgressEnableResult.tryParse(reply({'mutationCounter': '1'})),
          isNull);
      for (final bad in <Map<String, Object?>>[
        {...evidence(), 'evidenceId': 'XYZ'},
        {...evidence(), 'ownerGeneration': 0},
        {...evidence(), 'sessionLifecycle': -1},
        {...evidence(), 'extra': 1},
        Map.of(evidence())..remove('ownerEpoch'),
      ]) {
        expect(CloudEgressEnableResult.tryParse(reply({'expiryEvidence': bad})),
            isNull,
            reason: '$bad');
      }
    });

    test('knows the new ASR operations', () {
      for (final op in ['mintExpiry', 'invalidateExpiry', 'retireSuccessor']) {
        expect(CloudEgressEnableResult.tryParse({...reply(), 'operation': op}),
            isNotNull);
      }
    });
  });

  group('RecoveryEvidenceSnapshot', () {
    Map<String, Object?> snap(String kind, {Map<String, Object?>? record}) => {
          'kind': kind,
          'ownerGeneration': 3,
          'ownerEpoch': 1,
          'mutationCounter': 40,
          if (record != null) 'record': record,
        };
    test('expiry evidence carries the record and the evidence', () {
      final s =
          RecoveryEvidenceSnapshot.tryParse(snap('expiryEvidence', record: {
        'state': 'OFF',
        'transitionGeneration': 3,
        'reservedVersion': 4,
        'lifetimeOwnerGeneration': 3,
        'lifetimeOwnerEpoch': 1,
        'expiryEvidence': evidence(),
      }))!;
      expect(s.kind, RecoveryEvidenceKind.expiryEvidence);
      expect(s.expiryEvidence!.sessionLifecycle, 7);
      expect(s.mutationCounter, 40);
    });

    test('a positive kind missing what its predicate needs is malformed', () {
      expect(
          RecoveryEvidenceSnapshot.tryParse(snap('expiryEvidence', record: {
            'state': 'OFF',
            'transitionGeneration': 3,
            'reservedVersion': 4,
          })),
          isNull);
      expect(RecoveryEvidenceSnapshot.tryParse(snap('liveOn')), isNull);
      expect(RecoveryEvidenceSnapshot.tryParse({'kind': 'other'}), isNull);
      expect(RecoveryEvidenceSnapshot.tryParse({'kind': 'none'})!.kind,
          RecoveryEvidenceKind.none);
    });

    // Session-only refresh (Cloud OFF): only an agreed OFF record is OFF.
    test('verifiedOff needs a proven owner and an agreed OFF record', () {
      Map<String, Object?> rec(String state) => {
            'state': state,
            'transitionGeneration': 2,
            'reservedVersion': 1,
          };
      bool off(Map<String, Object?> raw) =>
          RecoveryEvidenceSnapshot.tryParse(raw)!.verifiedOff;
      expect(off(snap('none', record: rec('OFF'))), isTrue);
      // Native sends no record for an unreadable layer, a held or unreadable
      // pending, or disagreeing layers.
      expect(off(snap('none')), isFalse);
      expect(off({'kind': 'none', 'mutationCounter': 40}), isFalse,
          reason: 'unproven owner or barrier');
      expect(off(snap('none', record: rec('ON'))), isFalse);
      expect(off(snap('none', record: rec('DISABLING'))), isFalse);
      expect(off({...snap('none', record: rec('OFF'))}..remove('mutationCounter')),
          isFalse);
    });
  });

  group('the noting lane (§5)', () {
    late CloudEgressGate gate;
    final calls = <String>[];
    setUp(() {
      gate = CloudEgressGate();
      CloudEgressGate.instance = gate;
      NativeCaptureBridge.onProtectedNativeWrite =
          (method, {required identity, authority}) => gate.noteCause(
              EpochCause.native(method, identity: identity),
              authority: authority);
      NativeCaptureBridge.debugTreatHostAsNative = true;
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('money_companion/native_capture'),
              (call) async {
        calls.add('${call.method}@${gate.causePosition}');
        return null;
      });
    });
    tearDown(() {
      NativeCaptureBridge.debugTreatHostAsNative = false;
      CloudEgressGate.instance = CloudEgressGate();
    });

    test(
        'new writers append a POLICY cause before the channel call; reads do not',
        () async {
      final p0 = gate.causePosition;
      await expectLater(
          NativeCaptureBridge.invalidateExpiryEvidence(
              ownerUid: 'u', evidenceId: id),
          throwsA(anything)); // a null reply is malformed, after the call
      await expectLater(
          NativeCaptureBridge.retireSuccessor(
              ownerUid: 'u',
              successorGeneration: 2,
              ownerEpoch: 1,
              operationId: id),
          throwsA(anything));
      await expectLater(
          NativeCaptureBridge.mintExpiryEvidenceForLiveOn(
              ownerUid: 'u',
              ownerGeneration: 1,
              ownerEpoch: 1,
              transitionGeneration: 1,
              reservedVersion: 1,
              sessionLifecycle: 1,
              expectedCounter: 1),
          throwsA(anything));
      expect(calls, [
        'invalidateExpiryEvidence@${p0 + 1}',
        'retireSuccessor@${p0 + 2}',
        'mintExpiryEvidenceForLiveOn@${p0 + 3}',
      ]);
      expect(
          gate.foreignCauseSince(p0,
              kind: RefreshOpKind.routine, atLeast: CauseClass.identity),
          isFalse,
          reason: 'POLICY, not IDENTITY');
      await NativeCaptureBridge.inspectRecoveryEvidence(ownerUid: 'u');
      expect(await NativeCaptureBridge.confirmRecoveryEvidence(1), isFalse);
      await NativeCaptureBridge.inspectSuccessor(
          ownerUid: 'u',
          successorGeneration: 2,
          ownerEpoch: 1,
          operationId: id);
      expect(gate.causePosition, p0 + 3, reason: 'reads are not causes');
    });

    test('B4: only an explicitly attributed successor write is own',
        () async {
      final me = Object();
      bool foreign(int from) => gate.foreignCauseSince(from,
          kind: RefreshOpKind.asr, authority: me);
      const binding = CloudEgressEnableBinding(
          operationId: id,
          transitionGeneration: 3,
          reservedVersion: 1,
          ownerGeneration: 2,
          ownerEpoch: 1);

      var p = gate.causePosition;
      await expectLater(
          NativeCaptureBridge.retireSuccessor(
              ownerUid: 'u',
              successorGeneration: 2,
              ownerEpoch: 1,
              operationId: id,
              causeAuthority: me),
          throwsA(anything));
      await expectLater(
          NativeCaptureBridge.beginCloudEgressEnable(
              ownerUid: 'u',
              transitionGeneration: 3,
              reservedVersion: 1,
              successor: (evidenceId: id, expectedCounter: 4),
              causeAuthority: me),
          throwsA(anything));
      await expectLater(
          NativeCaptureBridge.writeCloudEgressEnableOn(
              ownerUid: 'u', binding: binding, causeAuthority: me),
          throwsA(anything));
      await expectLater(
          NativeCaptureBridge.finishCloudEgressEnable(
              ownerUid: 'u',
              binding: binding,
              abandon: true,
              causeAuthority: me),
          throwsA(anything));
      expect(gate.causePosition, p + 4);
      expect(foreign(p), isFalse);

      // The same write without an authority is foreign to every op.
      p = gate.causePosition;
      await expectLater(
          NativeCaptureBridge.retireSuccessor(
              ownerUid: 'u',
              successorGeneration: 2,
              ownerEpoch: 1,
              operationId: id),
          throwsA(anything));
      expect(foreign(p), isTrue);

      // An authority on a NON-successor begin (an explicit enable) is ignored.
      p = gate.causePosition;
      await expectLater(
          NativeCaptureBridge.beginCloudEgressEnable(
              ownerUid: 'u',
              transitionGeneration: 3,
              reservedVersion: 1,
              causeAuthority: me),
          throwsA(anything));
      expect(foreign(p), isTrue);

      // A write issued later from a microtask or timer scheduled by the op is
      // still foreign unless that call names the authority itself.
      p = gate.causePosition;
      await Future<void>(() => NativeCaptureBridge.setCloudEgressState(
          ownerUid: 'u',
          state: 'off',
          transitionGeneration: 9,
          reservedVersion: 1));
      expect(foreign(p), isTrue);
    });
  });
}
