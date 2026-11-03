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
        file = MemorySlot(),
        pendingSecure = MemorySlot() {
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
      store: CloudEgressStore.forTesting(
          secure: secure,
          file: file,
          native: native,
          pendingSecure: pendingSecure),
      activeOwner: () async => owner,
      drainTimeout: drain,
      nativeInflight: (_) async => (count: 0, latestDeadline: null),
      resolved: resolved,
      supabaseUrl: () => supabaseUrl,
      accountControlTtl: accountControlTtl,
      monotonic: monotonic,
    );
    // The memory slots keep their status, as the strict Keychain read does.
    gate.strictSecureSlot = (key) =>
        key == CloudEgressStore.kSecureKey ? secure : pendingSecure;
    gate.nativeVerifiedOff = (_) async => nativeOff;
  }

  /// What the strict native inspection reports for the session-only refresh.
  bool nativeOff = true;

  final String supabaseUrl;
  final MemorySlot secure;
  final MemorySlot file;

  /// The secure pending layer (the file one stays volatile).
  final MemorySlot pendingSecure;
  late final CloudEgressGate gate;
  String? owner = 'uid-a';

  /// Installs this gate process-wide (transport, ConsentAuthority).
  TestEgress install() {
    CloudEgressGate.instance = gate;
    return this;
  }
}
