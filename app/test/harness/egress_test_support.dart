import 'package:money_companion/core/privacy/cloud_egress_gate.dart';

/// An in-memory [DurableSlot] whose failures a test can script.
class MemorySlot implements DurableSlot {
  String? value;
  bool failReads = false;
  bool failWrites = false;
  int writes = 0;

  @override
  Future<SlotRead> read() async {
    if (failReads) return const SlotRead(SlotStatus.unreadable);
    return value == null
        ? const SlotRead(SlotStatus.absent)
        : SlotRead(SlotStatus.value, value);
  }

  @override
  Future<void> write(String v) async {
    if (failWrites) throw StateError('slot write failed');
    writes++;
    value = v;
  }

  @override
  Future<void> delete() async => value = null;
}

/// A gate over two [MemorySlot]s (and an optional scripted native slot).
class TestEgress {
  TestEgress({NativeEgressSlot? native, Duration drain = const Duration(milliseconds: 200)})
      : secure = MemorySlot(),
        file = MemorySlot() {
    gate = CloudEgressGate(
      store: CloudEgressStore(secure: secure, file: file, native: native),
      activeOwner: () async => owner,
      drainTimeout: drain,
      nativeInflight: (_) async => (count: 0, latestDeadline: null),
    );
  }

  final MemorySlot secure;
  final MemorySlot file;
  late final CloudEgressGate gate;
  String? owner = 'uid-a';

  /// Installs this gate process-wide (transport, ConsentAuthority).
  TestEgress install() {
    CloudEgressGate.instance = gate;
    return this;
  }
}
