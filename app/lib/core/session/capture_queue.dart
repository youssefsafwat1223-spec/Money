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
    int? transitionGeneration,
  });

  /// The owner epoch read before a publish (bumped by every owner clear).
  Future<int> captureOwnerEpoch();

  /// Clear the owner record. [clearHint] true at the start of an account
  /// transition; false at a plain sign-out (the hint keeps the BL-2 prompt
  /// possible). Waiting items of the previous owner are NOT purged (§4.2).
  Future<bool> clearCaptureOwner({bool clearHint = false});

  /// §4.4 barrier: step 1, resume check, step 5.
  Future<void> beginCaptureRemoval(String uid);

  /// The native barrier record read with absent / present / malformed distinct (a
  /// transport error throws). The native record holds only an HMAC of the uid, so
  /// a present barrier cannot name its uid.
  Future<CaptureRemovalBarrierRead> getCaptureRemovalBarrier();
  Future<void> finishCaptureRemoval(String uid);
}

/// [RemoveDataBarrier] over the queue bridge.
class CaptureQueueRemoveBarrier implements RemoveDataBarrier {
  CaptureQueueRemoveBarrier(this._queue);
  final CaptureQueueBridge _queue;

  @override
  Future<void> begin(String uid) => _queue.beginCaptureRemoval(uid);

  /// Always null: the native barrier cannot name its uid and none is invented
  /// from its hash. Presence is reported by [nativeBarrierPresent].
  @override
  Future<String?> pendingUid() async => null;

  /// F2: a bridge failure propagates (the caller treats it as "cannot complete"
  /// and blocks admission), and a barrier that is present but unreadable counts as
  /// present; only a successful read of "absent" is false.
  @override
  Future<bool> nativeBarrierPresent() async =>
      (await _queue.getCaptureRemovalBarrier()).presence !=
      CaptureRemovalBarrierPresence.absent;

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
    int? transitionGeneration,
  }) async {
    await NativeCaptureBridge.publishCaptureOwner(
      uid: uid,
      cloud: cloud,
      ai: ai,
      version: version,
      expectedEpoch: expectedEpoch,
      transitionGeneration: transitionGeneration,
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
  /// wipe), so a native barrier without one is not expected; when it happens it
  /// is left in place and admission stays blocked (see [RemoveDataBarrier]).
  @override
  Future<CaptureRemovalBarrierRead> getCaptureRemovalBarrier() =>
      NativeCaptureBridge.readCaptureRemovalBarrier();

  @override
  Future<void> finishCaptureRemoval(String uid) async {
    await NativeCaptureBridge.finishCaptureRemoval(uid);
    if (!await PendingNotificationActions.clear()) {
      throw const RemoveDataIncompleteException();
    }
  }
}
