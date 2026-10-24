import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';

/// Consent-security amendment, native subunit: the typed pending-enable bridge.
/// The native side is ios/Runner/SharedCaptureStore.swift (behavioural proof:
/// RunnerTests "Pending enable barrier"); this pins that the bridge sends the
/// exact owner-bound identity and that a null, malformed, wrong-operation,
/// wrong-owner-lifecycle or partial reply can never be read as a completed phase.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('money_companion/native_capture');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;

  const id = 'a1b2c3d4e5f60718293a4b5c6d7e8f90';
  const other = '0123456789abcdef0123456789abcdef';
  const binding = CloudEgressEnableBinding(
    operationId: id,
    transitionGeneration: 3,
    reservedVersion: 4,
    ownerGeneration: 7,
    ownerEpoch: 2,
  );

  void fake(Future<Object?> Function(MethodCall call) handler) {
    calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return handler(call);
    });
  }

  test('lifecycle fence sends exact binding and only confirms both retired layers', () async {
    Map<String, Object?> receipt() => {
      'contractVersion': 1, 'operation': 'revoke', 'status': 'done',
      'operationId': id, 'transitionGeneration': 3, 'reservedVersion': 4,
      'ownerGeneration': 7, 'ownerEpoch': 2,
      'barrier': [
        {'layer': 'file', 'outcome': 'absent'},
        {'layer': 'keychain', 'outcome': 'absent'},
      ],
      'egress': [for (final name in ['file', 'keychain']) {
        'layer': name, 'outcome': 'verified', 'state': 'OFF',
        'operationId': id, 'transitionGeneration': 3, 'reservedVersion': 4,
        'ownerGeneration': 7, 'ownerEpoch': 2,
      }],
    };
    Future<CloudEgressEnableResult?> revoke() =>
        NativeCaptureBridge.revokeCaptureAuthorizationLifetime(ownerUid: 'u-a', binding: binding);
    fake((_) async => receipt());
    expect((await revoke())!.confirmsLifetimeRevoked(binding), isTrue);
    expect(calls.single.method, 'revokeCaptureAuthorizationLifetime');
    expect(calls.single.arguments, {
      'ownerUid': 'u-a', 'operationId': id, 'transitionGeneration': 3,
      'reservedVersion': 4, 'ownerGeneration': 7, 'ownerEpoch': 2,
    });
    for (final raw in [null, {'done': true},
      {...receipt(), 'ownerEpoch': 3},
      {...receipt(), 'egress': [
        {'layer': 'file', 'outcome': 'verified', 'state': 'OFF'},
        {'layer': 'keychain', 'outcome': 'writeFailed'},
      ]},
      {...receipt(), 'status': 'incomplete'},
    ]) {
      fake((_) async => raw);
      expect((await revoke())?.confirmsLifetimeRevoked(binding) ?? false, isFalse);
    }
  });

  test('restrictive owner publication requires exact two-layer local receipt', () async {
    Map<String, Object?> receipt() => {
      'contractVersion': 1, 'operation': 'publishRestrictive', 'status': 'done',
      'owner': {'uid': 'u-a', 'uidHash': List.filled(64, 'a').join(), 'generation': 8},
      'ownerGeneration': 8, 'ownerEpoch': 2,
      'barrier': [
        {'layer': 'file', 'outcome': 'absent'},
        {'layer': 'keychain', 'outcome': 'absent'},
      ],
      'egress': [for (final name in ['file', 'keychain']) {
        'layer': name, 'outcome': 'verified', 'state': 'OFF',
        'transitionGeneration': 3, 'reservedVersion': 4,
        'ownerGeneration': 8, 'ownerEpoch': 2,
      }],
    };
    Future<RestrictiveCaptureOwnerReceipt?> publish() =>
        NativeCaptureBridge.publishRestrictiveCaptureOwner(uid: 'u-a', version: 4, expectedEpoch: 2);
    fake((_) async => receipt());
    expect((await publish())!.confirms(uid: 'u-a', expectedEpoch: 2, version: 4), isTrue);
    expect(calls.single.method, 'publishRestrictiveCaptureOwner');
    expect(calls.single.arguments, {'uid': 'u-a', 'version': 4, 'expectedEpoch': 2});
    for (final raw in [null, {'done': true},
      {...receipt(), 'ownerEpoch': 3},
      {...receipt(), 'owner': {'uid': 'u-b', 'uidHash': List.filled(64, 'a').join(), 'generation': 8}},
      {...receipt(), 'egress': []}, {...receipt(), 'status': 'incomplete'},
    ]) {
      fake((_) async => raw);
      expect((await publish())?.confirms(uid: 'u-a', expectedEpoch: 2, version: 4) ?? false, isFalse);
    }
  });

  setUp(() => NativeCaptureBridge.debugTreatHostAsNative = true);
  tearDown(() {
    NativeCaptureBridge.debugTreatHostAsNative = false;
    messenger.setMockMethodCallHandler(channel, null);
  });

  Map<String, Object?> layer(
    String name,
    String outcome, {
    String? state,
    int? generation,
    int? version,
    String? operationId,
    int? ownerGeneration,
    int? ownerEpoch,
  }) =>
      {
        'layer': name,
        'outcome': outcome,
        if (state != null) 'state': state,
        if (generation != null) 'transitionGeneration': generation,
        if (version != null) 'reservedVersion': version,
        if (operationId != null) 'operationId': operationId,
        if (ownerGeneration != null) 'ownerGeneration': ownerGeneration,
        if (ownerEpoch != null) 'ownerEpoch': ownerEpoch,
      };

  List<Map<String, Object?>> barrier(String outcome,
          {String operationId = id,
          int ownerGeneration = 7,
          int ownerEpoch = 2}) =>
      [
        for (final name in const ['file', 'keychain'])
          layer(name, outcome,
              generation: 3,
              version: 4,
              operationId: operationId,
              ownerGeneration: ownerGeneration,
              ownerEpoch: ownerEpoch),
      ];

  List<Map<String, Object?>> egress(String outcome,
          {String state = 'ON', int generation = 3, int version = 4}) =>
      [
        for (final name in const ['file', 'keychain'])
          layer(name, outcome,
              state: state, generation: generation, version: version),
      ];

  Map<String, Object?> reply(
    String operation,
    String status, {
    Object? barrierLayers,
    Object? egressLayers,
    String? operationId = id,
    int generation = 3,
    int version = 4,
    int? ownerGeneration = 7,
    int? ownerEpoch = 2,
  }) =>
      {
        'contractVersion': 1,
        'operation': operation,
        'status': status,
        'barrier': barrierLayers ?? barrier('verified'),
        'egress': egressLayers ?? const <Object?>[],
        if (operationId != null) 'operationId': operationId,
        'transitionGeneration': generation,
        'reservedVersion': version,
        if (ownerGeneration != null) 'ownerGeneration': ownerGeneration,
        if (ownerEpoch != null) 'ownerEpoch': ownerEpoch,
      };

  Future<CloudEgressEnableResult?> begin(
          {CloudEgressEnableBinding? resume}) =>
      NativeCaptureBridge.beginCloudEgressEnable(
          ownerUid: 'u-a',
          transitionGeneration: 3,
          reservedVersion: 4,
          resume: resume);

  group('begin', () {
    test('a fresh begin sends no resume identity; a verified reply binds the '
        'owner lifecycle', () async {
      fake((_) async => reply('begin', 'done'));
      final result = await begin();
      expect(calls.single.method, 'beginCloudEgressEnable');
      expect(calls.single.arguments,
          {'ownerUid': 'u-a', 'transitionGeneration': 3, 'reservedVersion': 4});
      expect(result!.status, CloudEgressTransitionStatus.done);
      expect(result.binding, binding);
      expect(
          result.confirmsBarrierEstablished(
              transitionGeneration: 3, reservedVersion: 4),
          isTrue);
      expect(
          result.confirmsBarrierEstablished(
              transitionGeneration: 4, reservedVersion: 4),
          isFalse,
          reason: 'bound to the generation it was created for');
    });

    test('a resume sends the original operation id AND original owner epoch',
        () async {
      fake((_) async => reply('begin', 'done'));
      final result = await begin(resume: binding);
      expect(calls.single.arguments, {
        'ownerUid': 'u-a',
        'transitionGeneration': 3,
        'reservedVersion': 4,
        'resumeOperationId': id,
        'resumeOwnerEpoch': 2,
      });
      expect(
          result!.confirmsBarrierEstablished(
              transitionGeneration: 3, reservedVersion: 4, resumed: binding),
          isTrue);
      const otherEpoch = CloudEgressEnableBinding(
        operationId: id,
        transitionGeneration: 3,
        reservedVersion: 4,
        ownerGeneration: 7,
        ownerEpoch: 3,
      );
      expect(
          result.confirmsBarrierEstablished(
              transitionGeneration: 3, reservedVersion: 4, resumed: otherEpoch),
          isFalse,
          reason: 'a resume that came back as another lifecycle is not it');
    });

    test('a resume must name the generation and version it asks for', () async {
      fake((_) async => reply('begin', 'done'));
      await expectLater(
          NativeCaptureBridge.beginCloudEgressEnable(
              ownerUid: 'u-a',
              transitionGeneration: 9,
              reservedVersion: 4,
              resume: binding),
          throwsArgumentError);
      expect(calls, isEmpty);
    });

    test('ownerMismatch, conflict, stale, uncertain, noBarrier never confirm',
        () async {
      for (final status in [
        'ownerMismatch',
        'conflict',
        'stale',
        'uncertain',
        'noBarrier',
      ]) {
        fake((_) async => reply('begin', status));
        final result = await begin();
        expect(result!.status.name, status);
        expect(
            result.confirmsBarrierEstablished(
                transitionGeneration: 3, reservedVersion: 4),
            isFalse,
            reason: status);
      }
    });

    test('a first use whose native owner is not committed reports it and has '
        'no binding to continue with', () async {
      fake((_) async => {
            'contractVersion': 1,
            'operation': 'begin',
            'status': 'ownerMismatch',
            'barrier': barrier('absent').map((l) => {
                  'layer': l['layer'],
                  'outcome': 'absent',
                }).toList(),
            'egress': const <Object?>[],
          });
      final result = await begin();
      expect(result!.status, CloudEgressTransitionStatus.ownerMismatch);
      expect(result.binding, isNull);
      expect(
          result.confirmsBarrierEstablished(
              transitionGeneration: 3, reservedVersion: 4),
          isFalse);
    });

    test('a partial barrier, another operation or another owner lifecycle in a '
        'layer is never established, even if the status says done', () async {
      final cases = <String, List<Map<String, Object?>>>{
        'writeFailed layer': [
          layer('file', 'verified',
              generation: 3,
              version: 4,
              operationId: id,
              ownerGeneration: 7,
              ownerEpoch: 2),
          layer('keychain', 'writeFailed'),
        ],
        'other operation': [
          layer('file', 'verified',
              generation: 3,
              version: 4,
              operationId: id,
              ownerGeneration: 7,
              ownerEpoch: 2),
          layer('keychain', 'verified',
              generation: 3,
              version: 4,
              operationId: other,
              ownerGeneration: 7,
              ownerEpoch: 2),
        ],
        'other owner epoch': barrier('verified', ownerEpoch: 9)
          ..[0] = layer('file', 'verified',
              generation: 3,
              version: 4,
              operationId: id,
              ownerGeneration: 7,
              ownerEpoch: 2),
        'other owner generation': barrier('verified')
          ..[1] = layer('keychain', 'verified',
              generation: 3,
              version: 4,
              operationId: id,
              ownerGeneration: 8,
              ownerEpoch: 2),
      };
      for (final entry in cases.entries) {
        for (final status in ['incomplete', 'done']) {
          fake((_) async =>
              reply('begin', status, barrierLayers: entry.value));
          expect(
              (await begin())!.confirmsBarrierEstablished(
                  transitionGeneration: 3, reservedVersion: 4),
              isFalse,
              reason: '${entry.key} / $status');
        }
      }
    });

    test('a reply without the owner binding has no binding and never confirms',
        () async {
      fake((_) async => reply('begin', 'done',
          ownerGeneration: null, ownerEpoch: null));
      final result = await begin();
      expect(result!.binding, isNull);
      expect(
          result.confirmsBarrierEstablished(
              transitionGeneration: 3, reservedVersion: 4),
          isFalse);
    });
  });

  group('malformed replies are failures, never results', () {
    Future<void> expectMalformed(Object? raw, {String? why}) async {
      fake((_) async => raw);
      await expectLater(
        begin(),
        throwsA(isA<CaptureQueueException>()
            .having((e) => e.code, 'code', 'malformed_transition_result')),
        reason: why,
      );
    }

    test('null, non-map, wrong contract and wrong operation', () async {
      await expectMalformed(null, why: 'null');
      await expectMalformed(true, why: 'bool');
      await expectMalformed({...reply('begin', 'done'), 'contractVersion': 2},
          why: 'contract');
      await expectMalformed(reply('writeOn', 'done'), why: 'wrong operation');
      await expectMalformed(reply('begin', 'maybe'), why: 'unknown status');
    });

    test('layer lists must be exactly file then keychain', () async {
      await expectMalformed(
          reply('begin', 'done', barrierLayers: [barrier('verified').first]),
          why: 'one layer');
      await expectMalformed(
          reply('begin', 'done',
              barrierLayers: barrier('verified').reversed.toList()),
          why: 'swapped');
      await expectMalformed(
          reply('begin', 'done', barrierLayers: const <Object?>[]),
          why: 'empty barrier');
      await expectMalformed(
          reply('begin', 'done', egressLayers: [egress('verified').first]),
          why: 'one egress layer');
      await expectMalformed(
          reply('begin', 'done', barrierLayers: [
            ...barrier('verified'),
            layer('file', 'verified'),
          ]),
          why: 'three layers');
    });

    test('unknown keys, outcomes, states, ids and invalid numbers', () async {
      await expectMalformed({...reply('begin', 'done'), 'extra': 1},
          why: 'unknown key');
      await expectMalformed(
          reply('begin', 'done', barrierLayers: [
            layer('file', 'perfect',
                generation: 3,
                version: 4,
                operationId: id,
                ownerGeneration: 7,
                ownerEpoch: 2),
            ...barrier('verified').skip(1),
          ]),
          why: 'unknown outcome');
      await expectMalformed(
          reply('begin', 'done', egressLayers: [
            layer('file', 'verified', state: 'MAYBE'),
            layer('keychain', 'verified', state: 'ON'),
          ]),
          why: 'unknown state');
      await expectMalformed(reply('begin', 'done', operationId: 'not-hex'),
          why: 'bad id');
      await expectMalformed(reply('begin', 'done', generation: -1),
          why: 'negative generation');
      await expectMalformed(reply('begin', 'done', ownerEpoch: -1),
          why: 'negative owner epoch');
      await expectMalformed(
          {...reply('begin', 'done'), 'ownerGeneration': '7'},
          why: 'string owner generation');
      await expectMalformed(
          reply('begin', 'done', barrierLayers: [
            {...barrier('verified').first, 'ownerEpoch': 'x'},
            barrier('verified').last,
          ]),
          why: 'string layer owner epoch');
    });

    test('a native error is a CaptureQueueException, not a result', () async {
      fake((_) async =>
          throw PlatformException(code: 'removal_in_progress', message: 'x'));
      await expectLater(
          begin(),
          throwsA(isA<CaptureQueueException>()
              .having((e) => e.code, 'code', 'removal_in_progress')));
    });
  });

  group('writeOn', () {
    Future<CloudEgressEnableResult?> writeOn() =>
        NativeCaptureBridge.writeCloudEgressEnableOn(
            ownerUid: 'u-a', binding: binding);

    test('sends the full owner-bound identity; ON must be read back from BOTH '
        'layers', () async {
      fake((_) async =>
          reply('writeOn', 'done', egressLayers: egress('verified')));
      final result = await writeOn();
      expect(calls.single.method, 'writeCloudEgressEnableOn');
      expect(calls.single.arguments, {
        'ownerUid': 'u-a',
        'operationId': id,
        'transitionGeneration': 3,
        'reservedVersion': 4,
        'ownerGeneration': 7,
        'ownerEpoch': 2,
      });
      expect(result!.confirmsOnWritten(binding), isTrue);
      const otherLifecycle = CloudEgressEnableBinding(
        operationId: id,
        transitionGeneration: 3,
        reservedVersion: 4,
        ownerGeneration: 7,
        ownerEpoch: 3,
      );
      expect(result.confirmsOnWritten(otherLifecycle), isFalse);
    });

    test('ownerMismatch, one layer short of ON, an OFF layer or an empty '
        'egress list never confirm', () async {
      fake((_) async =>
          reply('writeOn', 'ownerMismatch', egressLayers: egress('verified')));
      expect((await writeOn())!.confirmsOnWritten(binding), isFalse);
      for (final layers in <List<Map<String, Object?>>>[
        [
          layer('file', 'verified', state: 'ON', generation: 3, version: 4),
          layer('keychain', 'mismatch', state: 'OFF', generation: 3, version: 4),
        ],
        [
          layer('file', 'verified', state: 'ON', generation: 3, version: 4),
          layer('keychain', 'writeFailed'),
        ],
        egress('verified', state: 'OFF'),
        egress('verified', generation: 2),
        const [],
      ]) {
        fake((_) async => reply('writeOn', 'done', egressLayers: layers));
        expect((await writeOn())!.confirmsOnWritten(binding), isFalse);
      }
    });

    test('a different operation id is not confirmed', () async {
      fake((_) async => reply('writeOn', 'done',
          egressLayers: egress('verified'), operationId: other));
      expect((await writeOn())!.confirmsOnWritten(binding), isFalse);
    });
  });

  group('restrict', () {
    Future<CloudEgressEnableResult?> restrict() =>
        NativeCaptureBridge.restrictCloudEgressEnable(
            ownerUid: 'u-a', binding: binding);

    test('only restricted / alreadyRestrictive / superseded / absent layers '
        'confirm', () async {
      for (final outcomes in [
        ['restricted', 'restricted'],
        ['alreadyRestrictive', 'restricted'],
        ['superseded', 'restricted'],
        ['absent', 'restricted'],
      ]) {
        fake((_) async => reply('restrict', 'done', egressLayers: [
              layer('file', outcomes[0], state: 'OFF'),
              layer('keychain', outcomes[1], state: 'OFF'),
            ]));
        expect((await restrict())!.confirmsRestricted(binding), isTrue,
            reason: '$outcomes');
      }
      expect(calls.single.method, 'restrictCloudEgressEnable');
      expect(calls.single.arguments['ownerGeneration'], 7);
      expect(calls.single.arguments['ownerEpoch'], 2);
    });

    test('a restriction proven in only ONE layer is incomplete: the other '
        'layer\'s ON is reported notOurs and the call is never confirmed',
        () async {
      for (final outcomes in [
        ['restricted', 'notOurs'], // file-only barrier proof
        ['notOurs', 'restricted'], // keychain-only barrier proof (mirror)
      ]) {
        final layers = [
          layer('file', outcomes[0], state: outcomes[0] == 'restricted' ? 'OFF' : 'ON',
              generation: 3, version: 4),
          layer('keychain', outcomes[1],
              state: outcomes[1] == 'restricted' ? 'OFF' : 'ON',
              generation: 3, version: 4),
        ];
        fake((_) async => reply('restrict', 'incomplete', egressLayers: layers));
        final partial = await restrict();
        expect(partial!.status, CloudEgressTransitionStatus.incomplete);
        expect(partial.confirmsRestricted(binding), isFalse, reason: '$outcomes');
        // A reply that claims done over the same layers is still not accepted.
        fake((_) async => reply('restrict', 'done', egressLayers: layers));
        expect((await restrict())!.confirmsRestricted(binding), isFalse,
            reason: '$outcomes claimed done');
      }
    });

    test('unproven or unresolved state never confirms: noBarrier, uncertain, '
        'conflict and every non-restricting layer outcome', () async {
      for (final status in ['noBarrier', 'uncertain', 'conflict']) {
        fake((_) async => reply('restrict', status,
            egressLayers: egress('verified', state: 'ON')));
        expect((await restrict())!.confirmsRestricted(binding), isFalse,
            reason: status);
      }
      for (final bad in ['unreadable', 'notOurs', 'writeFailed', 'mismatch']) {
        fake((_) async => reply('restrict', 'incomplete', egressLayers: [
              layer('file', 'restricted', state: 'OFF'),
              layer('keychain', bad),
            ]));
        expect((await restrict())!.confirmsRestricted(binding), isFalse,
            reason: bad);
        fake((_) async => reply('restrict', 'done', egressLayers: [
              layer('file', 'restricted', state: 'OFF'),
              layer('keychain', bad),
            ]));
        expect((await restrict())!.confirmsRestricted(binding), isFalse,
            reason: '$bad even if the status claims done');
      }
    });
  });

  group('finish', () {
    Future<CloudEgressEnableResult?> finish({required bool abandon}) =>
        NativeCaptureBridge.finishCloudEgressEnable(
            ownerUid: 'u-a', binding: binding, abandon: abandon);

    test('complete needs ON in both layers AND the barrier cleared', () async {
      fake((_) async => reply('complete', 'done',
          barrierLayers: barrier('cleared'), egressLayers: egress('verified')));
      final result = await finish(abandon: false);
      expect(calls.single.method, 'finishCloudEgressEnable');
      expect(calls.single.arguments['abandon'], isFalse);
      expect(calls.single.arguments['ownerGeneration'], 7);
      expect(calls.single.arguments['ownerEpoch'], 2);
      expect(result!.confirmsCompleted(binding), isTrue);
      expect(result.confirmsAbandoned(binding), isFalse,
          reason: 'a completion is not an abandonment');
    });

    test('a complete from an older owner lifecycle is an ownerMismatch and '
        'never confirms', () async {
      fake((_) async => reply('complete', 'ownerMismatch',
          barrierLayers: barrier('verified'), egressLayers: egress('verified')));
      final result = await finish(abandon: false);
      expect(result!.status, CloudEgressTransitionStatus.ownerMismatch);
      expect(result.confirmsCompleted(binding), isFalse);
    });

    test('a partially cleared barrier is not complete', () async {
      fake((_) async => reply('complete', 'incomplete',
          barrierLayers: [
            layer('file', 'writeFailed',
                generation: 3,
                version: 4,
                operationId: id,
                ownerGeneration: 7,
                ownerEpoch: 2),
            layer('keychain', 'cleared'),
          ],
          egressLayers: egress('verified')));
      expect((await finish(abandon: false))!.confirmsCompleted(binding), isFalse);
    });

    test('complete without ON in both layers never confirms', () async {
      fake((_) async => reply('complete', 'done',
          barrierLayers: barrier('cleared'),
          egressLayers: [
            layer('file', 'verified', state: 'ON', generation: 3, version: 4),
            layer('keychain', 'absent'),
          ]));
      expect((await finish(abandon: false))!.confirmsCompleted(binding), isFalse);
    });

    test('abandon asks native with abandon:true and cannot be read as complete',
        () async {
      fake((_) async => reply('abandon', 'done',
          barrierLayers: barrier('cleared'),
          egressLayers: egress('verified', state: 'OFF')));
      final result = await finish(abandon: true);
      expect(calls.single.arguments['abandon'], isTrue);
      expect(result!.confirmsAbandoned(binding), isTrue);
      expect(result.confirmsCompleted(binding), isFalse);
    });

    test('an abandon reply that shows ANY ON for the owner never confirms, a '
        'prior generation included', () async {
      for (final layers in [
        egress('verified'),
        egress('verified', generation: 1, version: 2),
      ]) {
        fake((_) async => reply('abandon', 'done',
            barrierLayers: barrier('cleared'), egressLayers: layers));
        expect((await finish(abandon: true))!.confirmsAbandoned(binding),
            isFalse);
      }
    });

    test('the reply must belong to the asked operation', () async {
      fake((_) async => reply('abandon', 'done',
          barrierLayers: barrier('cleared'), egressLayers: egress('verified')));
      await expectLater(
          finish(abandon: false),
          throwsA(isA<CaptureQueueException>()
              .having((e) => e.code, 'code', 'malformed_transition_result')));
    });
  });

  group('inspect and platform', () {
    test('inspect parses a pending barrier read-only and exposes the binding '
        'a restart needs', () async {
      fake((_) async => reply('inspect', 'pending',
          barrierLayers: barrier('verified'),
          egressLayers: egress('verified', state: 'OFF', generation: 2)));
      final result =
          await NativeCaptureBridge.getCloudEgressPending(ownerUid: 'u-a');
      expect(calls.single.method, 'getCloudEgressPending');
      expect(calls.single.arguments, {'ownerUid': 'u-a'});
      expect(result!.status, CloudEgressTransitionStatus.pending);
      expect(result.binding, binding);
      expect(result.egress.first.state, 'OFF');
    });

    test('off iOS there is no native layer: null and no channel call',
        () async {
      NativeCaptureBridge.debugTreatHostAsNative = false;
      fake((_) async => throw StateError('must not be called'));
      // Host tests run on macOS/Linux, never iOS.
      expect(await begin(), isNull);
      expect(await NativeCaptureBridge.getCloudEgressPending(ownerUid: 'u-a'),
          isNull);
      expect(calls, isEmpty);
    });
  });
}
