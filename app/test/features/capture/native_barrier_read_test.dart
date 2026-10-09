import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/session/capture_queue.dart';
import 'package:money_companion/core/session/remove_data_flow.dart';
import 'package:money_companion/data/db/replica_store.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';

import '../../core/session/fake_account_scope.dart';
import '../../core/session/recording_secure_storage.dart';

// F2 round 2 (R2-6) — the native Remove-data barrier read keeps four outcomes
// DISTINCT: absent, present, malformed and error. Only a successful read of
// "absent" means nothing is pending; everything else keeps admission blocked.

class _Bridge implements CaptureQueueBridge {
  _Bridge(this.read);
  Future<CaptureRemovalBarrierRead> Function() read;
  final List<String> calls = [];

  @override
  Future<CaptureRemovalBarrierRead> getCaptureRemovalBarrier() {
    calls.add('get');
    return read();
  }

  @override
  Future<void> beginCaptureRemoval(String uid) async => calls.add('begin');

  @override
  Future<void> finishCaptureRemoval(String uid) async => calls.add('finish');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('money_companion/native_capture');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  group('R2-6 parsing keeps absent / present / malformed distinct', () {
    test('R2-6 CaptureRemovalBarrierRead.parse', () {
      expect(CaptureRemovalBarrierRead.parse(null).presence,
          CaptureRemovalBarrierPresence.absent);

      final present = CaptureRemovalBarrierRead.parse(
          {'nonce': 'n', 'uidHash': 'h', 'startedAt': 't'});
      expect(present.presence, CaptureRemovalBarrierPresence.present);
      expect(present.barrier!.uidHash, 'h');

      for (final bad in <Object>[
        'garbage',
        42,
        <String, Object?>{},
        {'nonce': 1, 'uidHash': 'h', 'startedAt': 't'},
        {'nonce': 'n', 'uidHash': null, 'startedAt': 't'},
        {'nonce': 'n', 'uidHash': 'h'},
      ]) {
        final read = CaptureRemovalBarrierRead.parse(bad);
        expect(read.presence, CaptureRemovalBarrierPresence.malformed,
            reason: '$bad is present-but-unreadable, never "absent"');
        expect(read.barrier, isNull);
      }
    });
  });

  group('R2-6 the bridge', () {
    setUp(() => NativeCaptureBridge.debugTreatHostAsNative = true);
    tearDown(() {
      NativeCaptureBridge.debugTreatHostAsNative = false;
      messenger.setMockMethodCallHandler(channel, null);
    });

    void fake(Future<Object?> Function() answer) =>
        messenger.setMockMethodCallHandler(channel, (_) => answer());

    test('R2-6 channel answers map to the four outcomes', () async {
      fake(() async => null);
      expect((await NativeCaptureBridge.readCaptureRemovalBarrier()).presence,
          CaptureRemovalBarrierPresence.absent);

      fake(() async => {'nonce': 'n', 'uidHash': 'h', 'startedAt': 't'});
      expect((await NativeCaptureBridge.readCaptureRemovalBarrier()).presence,
          CaptureRemovalBarrierPresence.present);

      fake(() async => {'nonce': 1});
      expect((await NativeCaptureBridge.readCaptureRemovalBarrier()).presence,
          CaptureRemovalBarrierPresence.malformed);

      fake(() async => throw PlatformException(code: 'queue_unavailable'));
      await expectLater(NativeCaptureBridge.readCaptureRemovalBarrier(),
          throwsA(isA<CaptureQueueException>()));

      messenger.setMockMethodCallHandler(channel, null);
      await expectLater(NativeCaptureBridge.readCaptureRemovalBarrier(),
          throwsA(isA<CaptureQueueException>()),
          reason: 'a missing plugin is an error, not "no barrier"');
    });

    test('R2-6 the diagnostics accessor still answers null for malformed',
        () async {
      fake(() async => {'nonce': 1});
      expect(await NativeCaptureBridge.getCaptureRemovalBarrier(), isNull);
    });
  });

  group('R2-6 the removal flow fails closed on all but a clean "absent"', () {
    late Directory support;
    setUp(() {
      support = Directory.systemTemp.createTempSync('barrier_read_');
      RecordingSecureStorage().install();
    });
    tearDown(() => support.deleteSync(recursive: true));

    RemoveDataFlow flowOver(_Bridge bridge) => RemoveDataFlow(
          store: ReplicaStore(appSupportDirectory: support.path),
          scope: FakeAccountScope(),
          barrier: CaptureQueueRemoveBarrier(bridge),
          clearOwnerMarker: (_) async {},
        );

    test('R2-6 absent => nothing pending; present, malformed, error => blocked',
        () async {
      final absent = _Bridge(() async =>
          const CaptureRemovalBarrierRead.absent());
      expect(await flowOver(absent).resumePending(), isTrue);

      final present = _Bridge(() async => CaptureRemovalBarrierRead.parse(
          {'nonce': 'n', 'uidHash': 'h', 'startedAt': 't'}));
      expect(await flowOver(present).resumePending(), isFalse);
      expect(present.calls, ['get'], reason: 'no begin/finish for a guessed uid');

      final malformed =
          _Bridge(() async => CaptureRemovalBarrierRead.parse({'nonce': 1}));
      expect(await flowOver(malformed).resumePending(), isFalse);
      expect(malformed.calls, ['get']);

      final failing = _Bridge(() async => throw StateError('transport'));
      expect(await flowOver(failing).resumePending(), isFalse);
      expect(failing.calls, ['get']);
    });
  });
}
