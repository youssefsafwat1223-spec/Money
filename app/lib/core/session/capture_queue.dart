import '../../features/capture/services/native_capture_bridge.dart';
import '../../features/capture/services/pending_notification_actions.dart';
import 'remove_data_flow.dart';

/// WP-3b — the narrow seam to the native capture queue (CAP-6a). Method names
/// match the `NativeCaptureBridge` statics of the same names; a fake stands in
/// for tests. Never carries SMS content.
abstract class CaptureQueueBridge {
  /// Publish [uid] as the queue's active owner with its consent mirror in one
  /// native flock, compare-and-swap on [expectedEpoch] (A-12-min R4). Called
  /// after the replica is admitted; Cloud ON gates it further on
  /// `link_capture_device(consent)`, Cloud OFF publishes locally.
  Future<void> publishCaptureOwner({
    required String uid,
    required bool cloud,
    required bool ai,
    required int version,
    required int expectedEpoch,
  });

  /// The owner epoch read before a publish (bumped by every owner clear).
  Future<int> captureOwnerEpoch();

  /// Clear the owner record. [clearHint] true at the start of an account
  /// transition; false at a plain sign-out (the hint keeps the BL-2 prompt
  /// possible). Waiting items of the previous owner are NOT purged (§4.2).
  Future<bool> clearCaptureOwner({bool clearHint = false});

  /// §4.4 barrier: step 1, resume check, step 5.
  Future<void> beginCaptureRemoval(String uid);
  Future<String?> getCaptureRemovalBarrier();
  Future<void> finishCaptureRemoval(String uid);
}

/// [RemoveDataBarrier] over the queue bridge.
class CaptureQueueRemoveBarrier implements RemoveDataBarrier {
  CaptureQueueRemoveBarrier(this._queue);
  final CaptureQueueBridge _queue;

  @override
  Future<void> begin(String uid) => _queue.beginCaptureRemoval(uid);

  @override
  Future<String?> pendingUid() => _queue.getCaptureRemovalBarrier();

  @override
  Future<void> finish(String uid) => _queue.finishCaptureRemoval(uid);
}

/// The CAP-6 native queue (v3). Bridge failures surface as exceptions, which the
/// removal flow turns into [RemoveDataIncompleteException] (barrier kept).
class NativeCaptureQueue implements CaptureQueueBridge {
  @override
  Future<void> publishCaptureOwner({
    required String uid,
    required bool cloud,
    required bool ai,
    required int version,
    required int expectedEpoch,
  }) async {
    await NativeCaptureBridge.publishCaptureOwner(
      uid: uid,
      cloud: cloud,
      ai: ai,
      version: version,
      expectedEpoch: expectedEpoch,
    );
  }

  @override
  Future<int> captureOwnerEpoch() => NativeCaptureBridge.captureOwnerEpoch();

  @override
  Future<bool> clearCaptureOwner({bool clearHint = false}) async {
    await NativeCaptureBridge.clearCaptureOwner(clearHint: clearHint);
    return true;
  }

  @override
  Future<void> beginCaptureRemoval(String uid) async {
    await NativeCaptureBridge.beginCaptureRemoval(uid);
  }

  /// The native barrier records only an HMAC of the uid, so it cannot name the
  /// uid. The Dart barrier record is written first (and survives a session
  /// wipe), so a native barrier without one is not expected; it is left in place.
  @override
  Future<String?> getCaptureRemovalBarrier() async => null;

  @override
  Future<void> finishCaptureRemoval(String uid) async {
    await NativeCaptureBridge.finishCaptureRemoval(uid);
    if (!await PendingNotificationActions.clear()) {
      throw const RemoveDataIncompleteException();
    }
  }
}
