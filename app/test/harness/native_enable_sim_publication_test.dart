import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';

import 'native_enable_sim.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('money_companion/native_capture');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  test('successful publication is immediately visible in both inspection layers',
      () async {
    final sim = NativeEnableSim();
    NativeCaptureBridge.debugTreatHostAsNative = true;
    messenger.setMockMethodCallHandler(channel, sim.handle);
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      NativeCaptureBridge.debugTreatHostAsNative = false;
    });
    final receipt = await NativeCaptureBridge.publishRestrictiveCaptureOwner(
        uid: sim.uid, version: 0, expectedEpoch: sim.ownerEpoch);
    expect(receipt, isNotNull);
    expect(receipt!.phase.egress, hasLength(2));
    final inspected = await NativeCaptureBridge.getCloudEgressPending(
        ownerUid: sim.uid);
    expect(inspected, isNotNull);
    expect(inspected!.egress, hasLength(2),
        reason: 'a successful publication wrote and verified both native slots');
    for (var i = 0; i < 2; i++) {
      final published = receipt.phase.egress[i];
      final held = inspected.egress[i];
      expect(held.layer, published.layer);
      expect(held.outcome, CloudEgressLayerOutcome.verified);
      expect(held.state, 'OFF');
      expect(held.transitionGeneration, published.transitionGeneration);
      expect(held.reservedVersion, published.reservedVersion);
      expect(held.ownerGeneration, published.ownerGeneration);
      expect(held.ownerEpoch, published.ownerEpoch);
      expect(held.operationId, isNull);
    }
  });
}
