import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';

/// G3 bridge contract (C.4 egress state, P4 generation guards, C.1 owner
/// generation) against a fake native channel. The native side is
/// ios/Runner/AppDelegate.swift + SharedCaptureStore.swift; the Dart
/// source-contract test test/architecture/cloud_egress_swift_g3_contract_test.dart
/// pins the same method names and error codes there.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('money_companion/native_capture');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;

  void fake(Future<Object?> Function(MethodCall call) handler) {
    calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return handler(call);
    });
  }

  setUp(() => NativeCaptureBridge.debugTreatHostAsNative = true);
  tearDown(() {
    NativeCaptureBridge.debugTreatHostAsNative = false;
    messenger.setMockMethodCallHandler(channel, null);
  });

  group('cloud egress state', () {
    test('set sends all four fields on the setCloudEgressState method',
        () async {
      fake((_) async => true);
      await NativeCaptureBridge.setCloudEgressState(
          state: 'DISABLING',
          ownerUid: 'u-a',
          transitionGeneration: 4,
          reservedVersion: 9);
      expect(calls.single.method, 'setCloudEgressState');
      expect(calls.single.arguments, {
        'state': 'DISABLING',
        'ownerUid': 'u-a',
        'transitionGeneration': 4,
        'reservedVersion': 9,
      });
    });

    test('a refused write surfaces its code (stale_generation)', () async {
      fake((_) async =>
          throw PlatformException(code: 'stale_generation', message: 'x'));
      await expectLater(
        NativeCaptureBridge.setCloudEgressState(
            state: 'ON',
            ownerUid: 'u-a',
            transitionGeneration: 1,
            reservedVersion: 2),
        throwsA(isA<CaptureQueueException>()
            .having((e) => e.code, 'code', 'stale_generation')),
      );
    });

    test('get parses record / unset / uncertain', () async {
      fake((_) async => {
            'status': 'record',
            'state': 'OFF',
            'ownerUid': 'u-a',
            'transitionGeneration': 4,
            'reservedVersion': 9,
          });
      final record =
          await NativeCaptureBridge.getCloudEgressState(ownerUid: 'u-a');
      expect(record?.status, CloudEgressStatus.record);
      expect(record?.state, 'OFF');
      expect(record?.ownerUid, 'u-a');
      expect(record?.transitionGeneration, 4);
      expect(record?.reservedVersion, 9);
      expect(calls.single.method, 'getCloudEgressState');
      expect(calls.single.arguments, {'ownerUid': 'u-a'});

      fake((_) async => {'status': 'unset'});
      expect(
          (await NativeCaptureBridge.getCloudEgressState(ownerUid: 'u-a'))
              ?.status,
          CloudEgressStatus.unset);

      fake((_) async => {'status': 'uncertain'});
      expect(
          (await NativeCaptureBridge.getCloudEgressState(ownerUid: 'u-a'))
              ?.uncertain,
          isTrue);
    });

    test('a malformed answer is null (caller fails closed), not a record',
        () async {
      for (final raw in <Object?>[
        null,
        'ON',
        {'status': 'record', 'state': 'OFF'},
        {'status': 'bogus'},
      ]) {
        fake((_) async => raw);
        expect(await NativeCaptureBridge.getCloudEgressState(ownerUid: 'u-a'),
            isNull);
      }
    });

    test('an unavailable native layer throws (caller fails closed)', () async {
      fake((_) async =>
          throw PlatformException(code: 'queue_unavailable', message: 'x'));
      await expectLater(
          NativeCaptureBridge.getCloudEgressState(ownerUid: 'u-a'),
          throwsA(isA<CaptureQueueException>()));
    });

    test('off iOS there is no native store: get is null, set is a no-op',
        () async {
      NativeCaptureBridge.debugTreatHostAsNative = false;
      fake((_) async => fail('must not call the channel'));
      expect(await NativeCaptureBridge.getCloudEgressState(ownerUid: 'u-a'),
          isNull);
      await NativeCaptureBridge.setCloudEgressState(
          state: 'OFF',
          ownerUid: 'u',
          transitionGeneration: 1,
          reservedVersion: 2);
      expect(calls, isEmpty);
    });
  });

  group('P4 generation parameters', () {
    test('legacy call sites send no transitionGeneration key', () async {
      fake((_) async => {'uid': 'u-a', 'uidHash': 'h', 'generation': 1});
      await NativeCaptureBridge.publishCaptureOwner(
          uid: 'u-a', cloud: true, ai: false, version: 1, expectedEpoch: 0);
      expect(calls.single.arguments, isNot(contains('transitionGeneration')));
      await NativeCaptureBridge.setCaptureConsentMirror(
          uid: 'u-a', cloud: true, ai: false, version: 2);
      expect(calls.last.arguments, isNot(contains('transitionGeneration')));
    });

    test('publish and mirror forward transitionGeneration', () async {
      fake((_) async => {'uid': 'u-a', 'uidHash': 'h', 'generation': 1});
      await NativeCaptureBridge.publishCaptureOwner(
          uid: 'u-a',
          cloud: false,
          ai: false,
          version: 1,
          expectedEpoch: 0,
          transitionGeneration: 6);
      expect(calls.single.arguments['transitionGeneration'], 6);
      await NativeCaptureBridge.setCaptureConsentMirror(
          uid: 'u-a',
          cloud: false,
          ai: false,
          version: 2,
          transitionGeneration: 6);
      expect(calls.last.arguments['transitionGeneration'], 6);
    });

    test('a stale mirror write is a CaptureQueueException', () async {
      fake((_) async =>
          throw PlatformException(code: 'stale_generation', message: 'x'));
      await expectLater(
        NativeCaptureBridge.setCaptureConsentMirror(
            uid: 'u-a',
            cloud: true,
            ai: true,
            version: 2,
            transitionGeneration: 1),
        throwsA(isA<CaptureQueueException>()
            .having((e) => e.code, 'code', 'stale_generation')),
      );
    });
  });

  group('C.1 owner generation on the upload authorization', () {
    test('allowed carries ownerUid and ownerGeneration', () async {
      fake((_) async => {
            'decision': 'allowed',
            'ownerUid': 'u-a',
            'ownerGeneration': 3,
            'allowAi': true,
            'contractV2': false,
          });
      final auth = await NativeCaptureBridge.authorizeCaptureUpload('p1');
      expect(auth.decision, CaptureUploadDecision.allowed);
      expect(auth.ownerUid, 'u-a');
      expect(auth.ownerGeneration, 3);
    });
  });

  group('native in-flight registry', () {
    test('parses count and latest deadline, scoped to the owner', () async {
      fake((_) async => {'count': 2, 'latestDeadlineMs': 1800000010000});
      final live =
          await NativeCaptureBridge.nativeInflightUploads(ownerUid: 'u-a');
      expect(live?.count, 2);
      expect(live?.latestDeadline,
          DateTime.fromMillisecondsSinceEpoch(1800000010000));
      expect(calls.single.method, 'nativeInflightUploads');
      expect(calls.single.arguments, {'ownerUid': 'u-a'});
    });

    test('none in flight has no deadline', () async {
      fake((_) async => {'count': 0});
      final live =
          await NativeCaptureBridge.nativeInflightUploads(ownerUid: 'u-a');
      expect(live?.count, 0);
      expect(live?.latestDeadline, isNull);
    });

    test('unavailable or malformed is null (caller waits the longest deadline)',
        () async {
      fake((_) async =>
          throw PlatformException(code: 'queue_unavailable', message: 'x'));
      expect(await NativeCaptureBridge.nativeInflightUploads(ownerUid: 'u-a'),
          isNull);
      for (final raw in <Object?>[
        null,
        'x',
        {'count': 'many'}
      ]) {
        fake((_) async => raw);
        expect(await NativeCaptureBridge.nativeInflightUploads(ownerUid: 'u-a'),
            isNull);
      }
    });

    test('off iOS there is no native process: nothing in flight', () async {
      NativeCaptureBridge.debugTreatHostAsNative = false;
      fake((_) async => fail('must not call the channel'));
      final live =
          await NativeCaptureBridge.nativeInflightUploads(ownerUid: 'u-a');
      expect(live?.count, 0);
      expect(calls, isEmpty);
    });
  });
}
