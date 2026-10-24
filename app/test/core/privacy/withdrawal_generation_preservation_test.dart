import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/core/session/admission_authority.dart';

import '../../harness/egress_test_support.dart';
import '../../harness/paused_egress_support.dart';

// N-R8 (Astra R7 N-CR-2a / N-CR-2b / Q11): a withdrawal helper never replaces a
// NEWER generation, whether the newer record is readable now, was unreadable on
// the first read, or appears while the helper is awaiting a read. The decision
// and the merge use ONE read of every relevant layer; a layer that cannot be
// verified refuses (fail closed). Preservation does not depend on the optional
// lifecycle predicate, and currency is rechecked before any write is dispatched.

/// A pausable slot whose reads can fail on a chosen call and can hook a read.
class _Slot extends PausedSlot {
  int reads = 0;
  final failReadsAt = <int>{};
  void Function(int n)? onRead;

  @override
  Future<SlotRead> read() async {
    reads++;
    onRead?.call(reads);
    if (failReadsAt.contains(reads)) {
      return const SlotRead(SlotStatus.unreadable);
    }
    return super.read();
  }
}

void main() {
  late _Slot secure;
  late _Slot file;
  late ScriptedNative native;
  late CloudEgressGate gate;
  late DisableFreeze freeze;

  Future<void> build() async {
    secure = _Slot();
    file = _Slot();
    native = ScriptedNative();
    gate = CloudEgressGate(
      store: CloudEgressStore(
          secure: secure,
          file: file,
          native: native.slot,
          pendingSecure: MemorySlot(),
          pendingFile: MemorySlot()),
      activeOwner: () async => kRigOwner,
      resolved: true,
      nativeInflight: (_) async => (count: 0, latestDeadline: null),
    );
    freeze = await gate.beginDisabling(owner: kRigOwner, reservedVersion: 2);
  }

  setUp(build);

  Future<List<CloudEgressRecord>> storedRecords() async {
    final seen = await gate.store.readOwnerLayers(kRigOwner);
    expect(seen.uncertain, isFalse);
    return seen.records;
  }

  CloudEgressRecord successor() =>
      rigRecord(EgressState.on, freeze.transitionGeneration + 1, 3);
  CloudEgressRecord mine(EgressState s) => freeze.record(s);

  /// The successor's ON exists in the SECURE layer alone.
  void successorInSecureOnly() => secure.value = rigEnvelope(successor());

  void expectSuccessorIntact() {
    expect(secure.value, rigEnvelope(successor()),
        reason: 'the successor record was not replaced');
  }

  group('N-CR-2a an unreadable layer is not proof of no newer generation', () {
    for (final op
        in <String, Future<bool> Function(CloudEgressGate, DisableFreeze)>{
      'commitOff': (g, f) => g.commitOff(f),
      'commitOff (isCurrent)': (g, f) => g.commitOff(f, isCurrent: () => true),
      'rewriteDisabling': (g, f) => g.rewriteDisabling(f),
      'rewriteDisabling (isCurrent)': (g, f) =>
          g.rewriteDisabling(f, isCurrent: () => true),
    }.entries) {
      test(
          '${op.key}: the newer record is unreadable on the first read and '
          'readable on the second: it is NOT replaced', () async {
        successorInSecureOnly();
        secure.failReadsAt.add(secure.reads + 1);
        final fileBefore = file.value;
        final nativeBefore = native.stored;
        expect(await op.value(gate, freeze), isFalse);
        expectSuccessorIntact();
        expect(file.value, fileBefore);
        expect(native.stored, nativeBefore);
      });

      test(
          '${op.key}: a persistently unreadable layer refuses and writes '
          'nothing', () async {
        successorInSecureOnly();
        secure.failReads = true;
        final writes = secure.writes + file.writes + native.writes;
        expect(await op.value(gate, freeze), isFalse);
        expect(secure.writes + file.writes + native.writes, writes);
        secure.failReads = false;
        expectSuccessorIntact();
      });

      test(
          '${op.key}: after the transient failure a retry sees the '
          'successor and still refuses', () async {
        successorInSecureOnly();
        secure.failReadsAt.add(secure.reads + 1);
        expect(await op.value(gate, freeze), isFalse);
        expect(await op.value(gate, freeze), isFalse);
        expectSuccessorIntact();
      });

      test('${op.key}: a corrupt layer refuses (nothing verifies it)',
          () async {
        file.value = 'not json';
        final writes = secure.writes + native.writes;
        expect(await op.value(gate, freeze), isFalse);
        expect(secure.writes + native.writes, writes);
        expect(file.value, 'not json', reason: 'never repaired here');
      });

      test('${op.key}: an unreadable native layer refuses', () async {
        final failing = ScriptedNative();
        final g = CloudEgressGate(
          store: CloudEgressStore(
              secure: secure,
              file: file,
              native: NativeEgressSlot(
                  read: (_) async => throw StateError('native read failed'),
                  write: failing.slot.write),
              pendingSecure: MemorySlot(),
              pendingFile: MemorySlot()),
          activeOwner: () async => kRigOwner,
          resolved: true,
          nativeInflight: (_) async => (count: 0, latestDeadline: null),
        );
        final writes = secure.writes + file.writes;
        expect(await op.value(g, freeze), isFalse);
        expect(secure.writes + file.writes, writes);
        expect(failing.writes, 0);
      });

      test(
          '${op.key}: with every layer readable and no newer record it '
          'lands in every store', () async {
        expect(await op.value(gate, freeze), isTrue);
        final want = op.key.startsWith('commitOff')
            ? EgressState.off
            : EgressState.disabling;
        expect(await storedRecords(), [mine(want), mine(want), mine(want)]);
      });
    }
  });

  group('N-CR-2b rewriteDisabling preserves a newer generation on its own', () {
    test('without isCurrent: a newer record in a readable layer is kept',
        () async {
      successorInSecureOnly();
      expect(await gate.rewriteDisabling(freeze), isFalse);
      expectSuccessorIntact();
      expect(file.value, isNot(contains(rigEnvelope(successor()))));
    });

    test('the native layer alone holding a newer record blocks it', () async {
      native.stored = successor();
      expect(await gate.rewriteDisabling(freeze), isFalse);
      expect(native.stored, successor());
    });

    test(
        'ordinary-disable recovery: the same call without a predicate keeps '
        'a successor ON', () async {
      await gate.writeRecord(successor());
      expect(await gate.rewriteDisabling(freeze), isFalse);
      expect(await storedRecords(), [successor(), successor(), successor()]);
    });
  });

  group('N-CR-2b currency is rechecked after the awaited validation', () {
    for (final op in <String,
        Future<bool> Function(CloudEgressGate, DisableFreeze, bool Function())>{
      'commitOff': (g, f, c) => g.commitOff(f, isCurrent: c),
      'rewriteDisabling': (g, f, c) => g.rewriteDisabling(f, isCurrent: c),
    }.entries) {
      test(
          '${op.key}: currency lost during the generation read dispatches '
          'no write', () async {
        var live = true;
        file.onRead = (_) => live = false; // revoked while reading
        final writes = secure.writes + file.writes + native.writes;
        await expectLater(op.value(gate, freeze, () => live),
            throwsA(isA<StaleAdmissionException>()));
        expect(secure.writes + file.writes + native.writes, writes);
        expect(await storedRecords(), [
          mine(EgressState.disabling),
          mine(EgressState.disabling),
          mine(EgressState.disabling)
        ]);
      });
    }
  });

  group('a stale exception after a write is not proof that nothing was written',
      () {
    for (final op in <String,
        Future<bool> Function(CloudEgressGate, DisableFreeze, bool Function())>{
      'commitOff': (g, f, c) => g.commitOff(f, isCurrent: c),
      'rewriteDisabling': (g, f, c) => g.rewriteDisabling(f, isCurrent: c),
    }.entries) {
      final want =
          op.key == 'commitOff' ? EgressState.off : EgressState.disabling;
      for (final boundary in ['secure', 'file']) {
        test(
            '${op.key}: currency lost after the $boundary write: stale '
            'result; the stored records are restrictive at the own '
            'generation, never a successor', () async {
          var live = true;
          final slot = boundary == 'secure' ? secure : file;
          final hold = slot.pauseAfterNextWrite();
          final running = op.value(gate, freeze, () => live);
          await slot.reached!.future;
          live = false;
          hold.complete();
          await expectLater(running, throwsA(isA<StaleAdmissionException>()));
          final seen = (await gate.store.readOwnerLayers(kRigOwner)).records;
          expect(seen, isNotEmpty);
          expect(seen.every((r) => r.restrictive), isTrue);
          expect(
              seen.every(
                  (r) => r.transitionGeneration == freeze.transitionGeneration),
              isTrue);
          expect(seen.where((r) => r.state == want), isNotEmpty,
              reason: 'a mutation DID happen: the exception does not deny it');
        });
      }
    }

    test(
        'a different owner\'s record is carried over untouched by every '
        'helper, stale or not', () async {
      final other = rigRecord(EgressState.on, 5, 9, 'uid-y');
      final body =
          '{"v":1,"records":{"uid-x":${_json(mine(EgressState.disabling))},'
          '"uid-y":${_json(other)}}}';
      secure.value = body;
      file.value = body;
      expect(await gate.rewriteDisabling(freeze), isTrue);
      expect(await gate.commitOff(freeze), isTrue);
      expect(
          (await gate.store.readOwnerLayers('uid-y')).records, [other, other]);
    });
  });
}

String _json(CloudEgressRecord r) => rigEnvelope(r)
    .split('"records":{"${r.ownerUid}":')[1]
    .replaceFirst('}}', '');
