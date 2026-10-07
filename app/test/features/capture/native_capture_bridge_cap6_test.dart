import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/entities/captured_message.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';

/// CAP-6a bridge contract (owner record, unbound claim, Remove-data barrier,
/// quota results) against a fake native channel. The native side is
/// ios/Runner/AppDelegate.swift + SharedCaptureStore.swift; the Dart
/// source-contract test test/architecture/capture_queue_cap6_contract_test.dart
/// pins that the same method names and error codes exist there.
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

  group('owner record', () {
    test('publish returns the native {uid, uidHash, generation}', () async {
      fake((_) async => {'uid': 'u-a', 'uidHash': 'h-a', 'generation': 7});
      final owner = await NativeCaptureBridge.publishCaptureOwner(
          uid: 'u-a', cloud: true, ai: false, version: 3, expectedEpoch: 5);
      expect(owner?.uid, 'u-a');
      expect(owner?.uidHash, 'h-a');
      expect(owner?.generation, 7);
      expect(calls.single.method, 'publishCaptureOwner');
      expect(calls.single.arguments, {
        'uid': 'u-a',
        'cloud': true,
        'ai': false,
        'version': 3,
        'expectedEpoch': 5,
      });
    });

    test('a malformed owner record is "no owner", not a crash', () async {
      fake((_) async => {'uid': 'u-a'});
      expect(await NativeCaptureBridge.getCaptureOwner(), isNull);
    });

    test('clear passes clearHint (transition vs sign-out)', () async {
      fake((_) async => true);
      await NativeCaptureBridge.clearCaptureOwner(clearHint: true);
      await NativeCaptureBridge.clearCaptureOwner(clearHint: false);
      expect(calls.map((c) => c.arguments), [
        {'clearHint': true},
        {'clearHint': false},
      ]);
    });

    test('a refused publish surfaces as CaptureQueueException with its code',
        () async {
      fake((_) async => throw PlatformException(
          code: 'removal_in_progress', message: 'QueueError.barrierActive'));
      await expectLater(
        NativeCaptureBridge.publishCaptureOwner(
            uid: 'u-a', cloud: true, ai: false, version: 3, expectedEpoch: 5),
        throwsA(isA<CaptureQueueException>()
            .having((e) => e.code, 'code', 'removal_in_progress')
            .having((e) => e.failure, 'failure',
                CaptureQueueFailure.removalInProgress)),
      );
    });

    test('an absent channel fails closed (it never reports success)', () async {
      fake((_) async => throw MissingPluginException());
      await expectLater(
        NativeCaptureBridge.clearCaptureOwner(clearHint: false),
        throwsA(isA<CaptureQueueException>()
            .having((e) => e.code, 'code', 'channel_unavailable')),
      );
    });

    test('consent mirror carries uid, both flags and the version', () async {
      fake((_) async => true);
      await NativeCaptureBridge.setCaptureConsentMirror(
          uid: 'u-a', cloud: true, ai: false, version: 4);
      expect(calls.single.method, 'setCaptureConsentMirror');
      expect(calls.single.arguments,
          {'uid': 'u-a', 'cloud': true, 'ai': false, 'version': 4});
    });
  });

  group('A-12-min: owner epoch, upload gate, queue stats', () {
    test('the owner epoch is read natively (0 off iOS)', () async {
      fake((_) async => 9);
      expect(await NativeCaptureBridge.captureOwnerEpoch(), 9);
      expect(calls.single.method, 'captureOwnerEpoch');
      NativeCaptureBridge.debugTreatHostAsNative = false;
      expect(await NativeCaptureBridge.captureOwnerEpoch(), 0);
    });

    test('authorizeUpload maps the allowed verdict with owner, AI and contract',
        () async {
      fake((_) async => {
            'decision': 'allowed',
            'ownerUid': 'u-a',
            'allowAi': true,
            'contractV2': true,
          });
      final auth = await NativeCaptureBridge.authorizeCaptureUpload('p1');
      expect(auth.allowed, isTrue);
      expect(auth.ownerUid, 'u-a');
      expect(auth.allowAi, isTrue);
      expect(auth.contractV2, isTrue);
      expect(calls.single.arguments, {'payloadId': 'p1'});
    });

    test('everything but a well-formed allowed verdict is zero egress',
        () async {
      for (final raw in <Object?>[
        {'decision': 'localOnly'},
        {'decision': 'allowed'}, // no owner
        {'decision': 'allowed', 'ownerUid': ''},
        {'decision': 'something-new'},
        'nonsense',
        null,
      ]) {
        fake((_) async => raw);
        expect((await NativeCaptureBridge.authorizeCaptureUpload('p')).allowed,
            isFalse,
            reason: '$raw');
      }
      fake((_) async => {'decision': 'waiting'});
      expect((await NativeCaptureBridge.authorizeCaptureUpload('p')).decision,
          CaptureUploadDecision.waiting);
      fake((_) async => throw PlatformException(code: 'queue_unavailable'));
      expect((await NativeCaptureBridge.authorizeCaptureUpload('p')).allowed,
          isFalse);
      fake((_) async => throw MissingPluginException());
      expect((await NativeCaptureBridge.authorizeCaptureUpload('p')).allowed,
          isFalse);
      NativeCaptureBridge.debugTreatHostAsNative = false;
      expect((await NativeCaptureBridge.authorizeCaptureUpload('p')).allowed,
          isFalse, reason: 'off iOS there is no native verdict');
    });

    test('captureQueueStats maps counts, bytes and quota state only',
        () async {
      fake((_) async => {
            'stamped': 4,
            'localOnly': 3,
            'waiting': 2,
            'unbound': 1,
            'activeOwnerBytes': 700,
            'unboundBytes': 90,
            'deviceBytes': 1200,
            'ownerQuota': 'near',
            'unboundQuota': 'ok',
            'deviceQuota': 'full',
          });
      final stats = (await NativeCaptureBridge.captureQueueStats())!;
      expect(calls.single.method, 'captureQueueStats');
      expect(stats.stamped, 4);
      expect(stats.localOnly, 3);
      expect(stats.waiting, 2);
      expect(stats.unbound, 1);
      expect(stats.total, 10);
      expect(stats.activeOwnerBytes, 700);
      expect(stats.unboundBytes, 90);
      expect(stats.deviceBytes, 1200);
      expect(stats.ownerQuota, CaptureQuotaState.near);
      expect(stats.unboundQuota, CaptureQuotaState.ok);
      expect(stats.deviceQuota, CaptureQuotaState.full);
    });

    test('stats ignore any extra (content) key and fail soft', () async {
      fake((_) async => {
            'stamped': 1,
            'text': 'SECRET',
            'sender': 'SECRET',
            'ownerQuota': 'bogus',
          });
      final stats = (await NativeCaptureBridge.captureQueueStats())!;
      expect(stats.toString(), isNot(contains('SECRET')));
      expect(stats.ownerQuota, CaptureQuotaState.ok);
      fake((_) async => throw PlatformException(code: 'queue_unavailable'));
      expect(await NativeCaptureBridge.captureQueueStats(), isNull);
      fake((_) async => 'not a map');
      expect(await NativeCaptureBridge.captureQueueStats(), isNull);
      NativeCaptureBridge.debugTreatHostAsNative = false;
      expect(await NativeCaptureBridge.captureQueueStats(), isNull);
    });
  });

  group('unbound claim', () {
    test('summary exposes a count and senders, plus the CAS snapshot ids',
        () async {
      fake((_) async => {
            'ids': ['i1', 'i2'],
            'senders': ['BANK1'],
            'count': 2,
          });
      final s = await NativeCaptureBridge.unboundCaptureSummary('u-a');
      expect(s.count, 2);
      expect(s.ids, ['i1', 'i2']);
      expect(s.senders, ['BANK1']);
      expect(calls.single.arguments, {'uid': 'u-a'});
    });

    test('claim sends every CAS input and maps applied / stale / mismatch',
        () async {
      for (final entry in const {
        'applied': CaptureClaimStatus.applied,
        'stale': CaptureClaimStatus.stale,
        'owner_mismatch': CaptureClaimStatus.ownerMismatch,
      }.entries) {
        fake((_) async => {'status': entry.key, 'count': 2});
        final r = await NativeCaptureBridge.claimUnboundCaptures(
          uid: 'u-a',
          generation: 3,
          replicaOwnerUid: 'u-a',
          sessionUid: 'u-a',
          ids: const ['i1', 'i2'],
        );
        expect(r.status, entry.value);
        expect(r.applied, entry.value == CaptureClaimStatus.applied);
        expect(calls.single.method, 'claimUnboundCaptures');
        expect(calls.single.arguments, {
          'uid': 'u-a',
          'generation': 3,
          'replicaOwnerUid': 'u-a',
          'sessionUid': 'u-a',
          'ids': ['i1', 'i2'],
        });
      }
    });

    test('an unknown or missing native status is treated as "did not happen"',
        () async {
      fake((_) async => {'status': 'something_new', 'count': 9});
      final r = await NativeCaptureBridge.claimUnboundCaptures(
        uid: 'u-a',
        generation: 1,
        replicaOwnerUid: 'u-a',
        sessionUid: 'u-a',
        ids: const ['i1'],
      );
      expect(r.applied, isFalse);
      expect(r.count, 0);
    });

    test('discard is the same contract on its own method', () async {
      fake((_) async => {'status': 'applied', 'count': 1});
      final r = await NativeCaptureBridge.discardUnboundCaptures(
        uid: 'u-a',
        generation: 1,
        replicaOwnerUid: 'u-a',
        sessionUid: 'u-a',
        ids: const ['i1'],
      );
      expect(r.applied, isTrue);
      expect(calls.single.method, 'discardUnboundCaptures');
    });
  });

  group('legacy v2 resolution and barrier', () {
    test('legacy verdict sends consumed and suspected ids', () async {
      fake((_) async => 2);
      final removed = await NativeCaptureBridge.resolveLegacyCaptureItems(
        consumedIds: const ['a', 'b'],
        suspectedIds: const ['c'],
      );
      expect(removed, 2);
      expect(calls.single.arguments, {
        'consumedIds': ['a', 'b'],
        'suspectedIds': ['c'],
      });
    });

    test('barrier begin / read / finish', () async {
      fake((call) async {
        switch (call.method) {
          case 'finishCaptureRemoval':
            return 4;
          default:
            return {'nonce': 'n1', 'uidHash': 'h-a', 'startedAt': 't0'};
        }
      });
      final begun = await NativeCaptureBridge.beginCaptureRemoval('u-a');
      expect(begun?.nonce, 'n1');
      expect((await NativeCaptureBridge.getCaptureRemovalBarrier())?.uidHash,
          'h-a');
      expect(await NativeCaptureBridge.finishCaptureRemoval('u-a'), 4);
      expect(calls.map((c) => c.method), [
        'beginCaptureRemoval',
        'getCaptureRemovalBarrier',
        'finishCaptureRemoval',
      ]);
    });
  });

  group('re-enqueue and quota results', () {
    // reEnqueueSharedMessage is iOS-only (Platform.isIOS); the host test runs on
    // neither, so it reports the unavailable failure without calling native.
    test('off-device the re-enqueue reports a failure, never success',
        () async {
      fake((_) async => null);
      const message = SharedCapturedMessage(
          text: 't', source: CapturedMessageSource.unknown);
      expect(
        await NativeCaptureBridge.reEnqueueSharedMessageChecked(message),
        CaptureQueueFailure.unavailable,
      );
      expect(
          await NativeCaptureBridge.reEnqueueSharedMessage(message), isFalse);
      expect(calls, isEmpty);
    });

    test('native error codes map to typed quota / removal / owner failures',
        () {
      expect(const CaptureQueueException('quota_exceeded').failure,
          CaptureQueueFailure.quotaExceeded);
      expect(const CaptureQueueException('removal_in_progress').failure,
          CaptureQueueFailure.removalInProgress);
      expect(const CaptureQueueException('owner_changed').failure,
          CaptureQueueFailure.ownerChanged);
      expect(const CaptureQueueException('queue_unavailable').failure,
          CaptureQueueFailure.unavailable);
    });
  });

  test('the v2 contract mirror defaults OFF and is sent to native', () {
    // setBackendConfig is iOS-only (Platform.isIOS), so a host test cannot drive
    // it; pin the default and the wire key instead.
    final src = File(
      'lib/features/capture/services/native_capture_bridge.dart',
    ).readAsStringSync();
    expect(src, contains('bool captureContractV2 = false'));
    expect(src, contains("'captureContractV2': captureContractV2"));
  });
}
