import 'dart:async';
import 'dart:convert';

import 'package:money_companion/core/privacy/cloud_egress_gate.dart';

import 'egress_test_support.dart';

/// Task 01 rig: a real [CloudEgressGate] over a real [CloudEgressStore] with two
/// pausable in-memory slots and a native copy that refuses stale generations
/// exactly like `SharedCaptureStore.setCloudEgressState`.

const kRigOwner = 'uid-x';

CloudEgressRecord rigRecord(EgressState state, int generation,
        [int version = 1, String owner = kRigOwner]) =>
    CloudEgressRecord(
        state: state,
        ownerUid: owner,
        transitionGeneration: generation,
        reservedVersion: version);

String rigEnvelope(CloudEgressRecord r) => jsonEncode({
      'v': 1,
      'records': {r.ownerUid: r.toJson()},
    });

/// A durable slot whose write can be paused AFTER the value landed, and failed
/// once on demand.
class PausedSlot extends MemorySlot {
  Completer<void>? reached;
  Completer<void>? _hold;
  bool failNextWrite = false;

  Completer<void> pauseAfterNextWrite() {
    reached = Completer<void>();
    return _hold = Completer<void>();
  }

  @override
  Future<void> write(String v) async {
    if (failNextWrite) {
      failNextWrite = false;
      throw StateError('slot write failed');
    }
    await super.write(v);
    final hold = _hold;
    if (hold != null) {
      _hold = null;
      reached!.complete();
      await hold.future;
    }
  }
}

class ScriptedNative {
  CloudEgressRecord? stored;
  bool failWrites = false;
  int writes = 0;

  static int _rank(EgressState s) => switch (s) {
        EgressState.on => 0,
        EgressState.disabling => 1,
        EgressState.off => 2,
      };

  late final NativeEgressSlot slot = NativeEgressSlot(
    read: (o) async => stored?.ownerUid == o ? stored : null,
    write: (r) async {
      if (failWrites) throw StateError('native write failed');
      final s = stored;
      if (s != null &&
          (r.transitionGeneration < s.transitionGeneration ||
              (r.transitionGeneration == s.transitionGeneration &&
                  _rank(r.state) < _rank(s.state)))) {
        throw StateError('stale generation');
      }
      writes++;
      stored = r;
    },
  );
}

class EgressRig {
  final secure = PausedSlot();
  final file = PausedSlot();
  final native = ScriptedNative();

  /// The two Dart layers of the durable pending-enable denial (N-E).
  final pendingSecure = PausedSlot();
  final pendingFile = PausedSlot();
  late final CloudEgressGate gate = CloudEgressGate(
    store: CloudEgressStore(
        secure: secure,
        file: file,
        native: native.slot,
        pendingSecure: pendingSecure,
        pendingFile: pendingFile),
    activeOwner: () async => kRigOwner,
    resolved: true,
    nativeInflight: (_) async => (count: 0, latestDeadline: null),
  );

  /// [owner]'s record as each store holds it (no merge).
  Future<List<CloudEgressRecord>> layers([String owner = kRigOwner]) async =>
      (await gate.store.readOwnerLayers(owner)).records;

  void failAllWrites() {
    secure.failWrites = true;
    file.failWrites = true;
    native.failWrites = true;
  }
}
