import 'dart:convert';

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
  /// [resolved] defaults to true (a bootstrapped process); pass false for the
  /// startup tests. [seedOn] pre-writes a durable ON record for [owner] (the
  /// state of a user who explicitly enabled Cloud), used by the default gate of
  /// every test that is not about the gate itself.
  TestEgress({
    NativeEgressSlot? native,
    Duration drain = const Duration(milliseconds: 200),
    bool resolved = true,
    bool seedOn = false,
    this.supabaseUrl = 'https://example.supabase.co',
    Duration accountControlTtl = kAccountControlTtl,
    Duration Function()? monotonic,
  })  : secure = MemorySlot(),
        file = MemorySlot() {
    if (seedOn) {
      final body = jsonEncode({
        'v': 1,
        'records': {
          'uid-a': const CloudEgressRecord(
                  state: EgressState.on,
                  ownerUid: 'uid-a',
                  transitionGeneration: 1,
                  reservedVersion: 1)
              .toJson()
        }
      });
      secure.value = body;
      file.value = body;
    }
    gate = CloudEgressGate(
      store: CloudEgressStore(secure: secure, file: file, native: native),
      activeOwner: () async => owner,
      drainTimeout: drain,
      nativeInflight: (_) async => (count: 0, latestDeadline: null),
      resolved: resolved,
      supabaseUrl: () => supabaseUrl,
      accountControlTtl: accountControlTtl,
      monotonic: monotonic,
    );
  }

  final String supabaseUrl;
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
