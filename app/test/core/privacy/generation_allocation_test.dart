import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/core/session/admission_authority.dart';

import '../../harness/egress_test_support.dart';
import '../../harness/paused_egress_support.dart';

// N-R9 (Astra R8 section 6 / Q8): a transition's generation is allocated from a
// VERIFIED MAXIMUM over every relevant layer record (secure, file, native), not
// from the restrictive merge winner, and is written without replacing anything
// newer or unseen. A layer that cannot be verified refuses the allocation
// (nothing is written, the caller's freeze stays); a stale caller writes nothing.

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

String _env(Map<String, CloudEgressRecord> records) => jsonEncode({
      'v': 1,
      'records': {for (final e in records.entries) e.key: e.value.toJson()},
    });

void main() {
  late _Slot secure;
  late _Slot file;
  late ScriptedNative native;
  late CloudEgressGate gate;

  CloudEgressRecord rec(EgressState s, int g,
          [int v = 1, String owner = kRigOwner]) =>
      rigRecord(s, g, v, owner);

  setUp(() {
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
  });

  Future<List<CloudEgressRecord>> layers([String o = kRigOwner]) async {
    final seen = await gate.store.readOwnerLayers(o);
    expect(seen.uncertain, isFalse);
    return seen.records;
  }

  int writesNow() => secure.writes + file.writes + native.writes;

  /// The two entry points that allocate a generation.
  final entries = <String, Future<int> Function(CloudEgressGate,
      {bool Function()? isCurrent})>{
    'beginDisabling': (g, {isCurrent}) async => (await g.beginDisabling(
            owner: kRigOwner, reservedVersion: 2, isCurrent: isCurrent))
        .transitionGeneration,
    'enable': (g, {isCurrent}) async => (await g.enable(
            owner: kRigOwner, reservedVersion: 2, isCurrent: isCurrent))
        .transitionGeneration,
  };

  for (final entry in entries.entries) {
    group('${entry.key}: allocation', () {
      test(
          'older restrictive record (OFF g2) in one layer and a newer ON (g10) '
          'in another, every layer readable: the next generation is above 10',
          () async {
        secure.value = rigEnvelope(rec(EgressState.off, 2));
        file.value = rigEnvelope(rec(EgressState.on, 10));
        final gen = await entry.value(gate);
        expect(gen, 11);
        expect((await layers()).map((r) => r.transitionGeneration),
            everyElement(11));
      });

      test('native-only newer ON evidence (g10) is part of the maximum',
          () async {
        secure.value = rigEnvelope(rec(EgressState.off, 2));
        file.value = rigEnvelope(rec(EgressState.off, 2));
        native.stored = rec(EgressState.on, 10);
        expect(await entry.value(gate), 11);
      });

      test('native rejection never restores or lowers a Dart record',
          () async {
        secure.value = rigEnvelope(rec(EgressState.off, 2));
        native.stored = rec(EgressState.on, 10);
        native.failWrites = true;
        // The restrictive record still lands in the Dart layers; the native
        // refusal is reported (disabling: any layer; enable: partial throws).
        try {
          await entry.value(gate);
        } on EgressWriteFailedException {
          // enable: partial write is reported, never swallowed
        }
        for (final r in await layers()) {
          if (r == native.stored) continue;
          expect(r.transitionGeneration, greaterThanOrEqualTo(11));
        }
        expect(native.stored, rec(EgressState.on, 10));
      });

      test(
          'a transiently unreadable HIGHER generation refuses: nothing is '
          'written and the unseen record is intact', () async {
        secure.value = rigEnvelope(rec(EgressState.on, 10));
        file.value = rigEnvelope(rec(EgressState.off, 2));
        secure.failReadsAt.add(secure.reads + 1);
        final before = writesNow();
        await expectLater(
            entry.value(gate), throwsA(isA<EgressWriteFailedException>()));
        expect(writesNow(), before);
        expect(secure.value, rigEnvelope(rec(EgressState.on, 10)));
        expect(file.value, rigEnvelope(rec(EgressState.off, 2)));
      });

      test('a newer file record arriving during secure dispatch survives',
          () async {
        secure.value = rigEnvelope(rec(EgressState.off, 2));
        file.value = rigEnvelope(rec(EgressState.on, 10));
        final hold = secure.pauseAfterNextWrite();
        final running = entry.value(gate);
        // Enable must report the refused layer; disabling may still establish
        // its restrictive record in another runtime.
        final done = running.then<void>((_) {}, onError: (Object error) {
          expect(error, isA<EgressWriteFailedException>());
        });
        await secure.reached!.future;
        final successor = rec(EgressState.on, 20);
        final unrelated = rec(EgressState.on, 33, 9, 'uid-y');
        file.value = _env({kRigOwner: successor, 'uid-y': unrelated});
        hold.complete();
        await done;
        expect(file.value, _env({kRigOwner: successor, 'uid-y': unrelated}));
        expect(file.writes, 0,
            reason: 'dispatch must refuse the newer generation');
      });

      test('a file becoming unreadable during secure dispatch is untouched',
          () async {
        secure.value = rigEnvelope(rec(EgressState.off, 2));
        file.value = rigEnvelope(rec(EgressState.on, 10));
        final hold = secure.pauseAfterNextWrite();
        final running = entry.value(gate);
        final done = running.then<void>((_) {}, onError: (Object error) {
          expect(error, isA<EgressWriteFailedException>());
        });
        await secure.reached!.future;
        file.failReads = true;
        hold.complete();
        await done;
        expect(file.value, rigEnvelope(rec(EgressState.on, 10)));
        expect(file.writes, 0);
      });

      test('dispatch carries newly persisted unrelated-owner evidence',
          () async {
        final hold = secure.pauseAfterNextWrite();
        final running = entry.value(gate);
        await secure.reached!.future;
        final unrelated = rec(EgressState.on, 33, 9, 'uid-y');
        file.value = _env({'uid-y': unrelated});
        hold.complete();
        await running;
        final parsed = jsonDecode(file.value!) as Map;
        expect(parsed['records']['uid-y'], unrelated.toJson());
      });

      test('a persistently unreadable layer refuses; recovery then allocates',
          () async {
        secure.value = rigEnvelope(rec(EgressState.on, 10));
        secure.failReads = true;
        final before = writesNow();
        await expectLater(
            entry.value(gate), throwsA(isA<EgressWriteFailedException>()));
        expect(writesNow(), before);
        secure.failReads = false;
        expect(await entry.value(gate), 11);
      });

      test('a corrupt layer refuses and is never repaired here', () async {
        file.value = 'not json';
        final before = writesNow();
        await expectLater(
            entry.value(gate), throwsA(isA<EgressWriteFailedException>()));
        expect(writesNow(), before);
        expect(file.value, 'not json');
      });

      test('an unreadable native layer refuses', () async {
        final g = CloudEgressGate(
          store: CloudEgressStore(
              secure: secure,
              file: file,
              native: NativeEgressSlot(
                  read: (_) async => throw StateError('native read failed'),
                  write: native.slot.write),
              pendingSecure: MemorySlot(),
              pendingFile: MemorySlot()),
          activeOwner: () async => kRigOwner,
          resolved: true,
          nativeInflight: (_) async => (count: 0, latestDeadline: null),
        );
        await expectLater(
            entry.value(g), throwsA(isA<EgressWriteFailedException>()));
        expect(writesNow(), 0);
      });

      test('currency lost during the allocation read writes nothing',
          () async {
        secure.value = rigEnvelope(rec(EgressState.off, 2));
        var live = true;
        file.onRead = (_) => live = false;
        final before = writesNow();
        await expectLater(entry.value(gate, isCurrent: () => live),
            throwsA(isA<StaleAdmissionException>()));
        expect(writesNow(), before);
        expect(secure.value, rigEnvelope(rec(EgressState.off, 2)));
      });

      test('currency lost at the dispatch read writes nothing', () async {
        secure.value = rigEnvelope(rec(EgressState.off, 2));
        var live = true;
        // The first secure read allocates; the second verifies dispatch.
        secure.onRead = (n) {
          if (n == 2) live = false;
        };
        await expectLater(entry.value(gate, isCurrent: () => live),
            throwsA(isA<StaleAdmissionException>()));
        expect(writesNow(), 0);
        expect(secure.value, rigEnvelope(rec(EgressState.off, 2)));
      });

      test('an unrelated owner\'s envelope entry is carried over everywhere',
          () async {
        final y = rec(EgressState.on, 5, 9, 'uid-y');
        final body = _env({
          kRigOwner: rec(EgressState.off, 2),
          'uid-y': y,
        });
        secure.value = body;
        file.value = _env({kRigOwner: rec(EgressState.on, 10), 'uid-y': y});
        expect(await entry.value(gate), 11);
        expect((await layers('uid-y')), [y, y]);
      });

      test(
          'a same-owner successor persisted while this call waits behind the '
          'gate lock is part of the maximum', () async {
        // A first transition holds the lock (paused after its file write).
        final hold = file.pauseAfterNextWrite();
        final first = gate.beginDisabling(owner: 'uid-z', reservedVersion: 2);
        await file.reached!.future;
        final queued = entry.value(gate);
        // Successor evidence for the queued owner lands while it is queued.
        file.value = _env({
          kRigOwner: rec(EgressState.on, 10),
          'uid-z': rec(EgressState.disabling, 1, 2, 'uid-z'),
        });
        secure.value = _env({kRigOwner: rec(EgressState.off, 2)});
        hold.complete();
        await first;
        expect(await queued, 11);
      });

      test(
          'a DIFFERENT owner\'s transition queued before it is preserved '
          'while this owner allocates above its own maximum', () async {
        secure.value = rigEnvelope(rec(EgressState.off, 2));
        file.value = rigEnvelope(rec(EgressState.on, 10));
        final other =
            gate.beginDisabling(owner: 'uid-y', reservedVersion: 2);
        final mine = entry.value(gate);
        await other;
        expect(await mine, 11);
        expect((await layers('uid-y')).map((r) => r.state),
            everyElement(EgressState.disabling));
      });
    });
  }

  group('enable: compensation never lowers or overwrites unseen authority', () {
    test(
        'a partial write whose compensation meets a NEWER record in a layer '
        'keeps it', () async {
      native.failWrites = true; // partial: enable must compensate
      final hold = file.pauseAfterNextWrite();
      final running = gate.enable(owner: kRigOwner, reservedVersion: 2);
      final outcome = expectLater(
          running, throwsA(isA<EgressWriteFailedException>()));
      await file.reached!.future;
      // A successor ON (g12) lands in the secure layer after our write.
      secure.value = rigEnvelope(rec(EgressState.on, 12));
      hold.complete();
      await outcome;
      expect(secure.value, rigEnvelope(rec(EgressState.on, 12)),
          reason: 'the newer authority was not replaced by the compensation');
    });

    test('a newer layer does not excuse leaving this operation ON elsewhere',
        () async {
      final written = rec(EgressState.on, 11);
      secure.value = rigEnvelope(rec(EgressState.on, 12));
      file.value = rigEnvelope(written);
      native.stored = written;
      expect(await gate.restrictWrittenOn(written), isTrue);
      expect(secure.value, rigEnvelope(rec(EgressState.on, 12)));
      expect(file.value, rigEnvelope(written.copyWith(state: EgressState.off)));
      expect(native.stored, written.copyWith(state: EgressState.off));
    });

    test(
        'restrictWrittenOn does not overwrite an unreadable (corrupt) layer',
        () async {
      final written = rec(EgressState.on, 11);
      secure.value = rigEnvelope(written);
      file.value = 'not json';
      expect(await gate.restrictWrittenOn(written), isFalse);
      expect(file.value, 'not json');
      expect(secure.value, rigEnvelope(written.copyWith(state: EgressState.off)));
    });
  });

  group('generic reconciliation and Dart-only writes', () {
    test('writeRecord cannot lower a generation or normalize other owners',
        () async {
      final yOff = rec(EgressState.off, 2, 9, 'uid-y');
      final yOn = rec(EgressState.on, 30, 9, 'uid-y');
      final first = _env({kRigOwner: rec(EgressState.off, 2), 'uid-y': yOff});
      final second = _env({kRigOwner: rec(EgressState.on, 10), 'uid-y': yOn});
      secure.value = first;
      file.value = second;
      final result = await gate.writeRecord(rec(EgressState.off, 3));
      expect(result.any, isFalse);
      expect(secure.value, first);
      expect(file.value, second);
      expect(writesNow(), 0);
    });

    test('writeDartOn preserves a newer Dart generation', () async {
      secure.value = rigEnvelope(rec(EgressState.on, 20));
      final result = await gate.writeDartOn(rec(EgressState.on, 3));
      expect(result.secure, isFalse);
      expect(secure.value, rigEnvelope(rec(EgressState.on, 20)));
      expect(secure.writes, 0);
      expect(native.writes, 0);
    });
  });

  group('alignOff (settings more restrictive than the record)', () {
    test('allocates above the maximum of every layer and keeps other owners',
        () async {
      final y = rec(EgressState.on, 5, 9, 'uid-y');
      secure.value = _env({kRigOwner: rec(EgressState.on, 5), 'uid-y': y});
      file.value = _env({kRigOwner: rec(EgressState.on, 9), 'uid-y': y});
      final w = await gate.alignOff(rec(EgressState.on, 5));
      expect(w, isNotNull);
      expect((await layers()).map((r) => r.transitionGeneration),
          everyElement(10));
      expect((await layers()).map((r) => r.state),
          everyElement(EgressState.off));
      expect((await layers('uid-y')), [y, y]);
    });

    test('an unverifiable layer refuses and writes nothing', () async {
      secure.value = rigEnvelope(rec(EgressState.on, 5));
      file.value = 'not json';
      final before = writesNow();
      expect(await gate.alignOff(rec(EgressState.on, 5)), isNull);
      expect(writesNow(), before);
      expect(file.value, 'not json');
    });
  });
}
