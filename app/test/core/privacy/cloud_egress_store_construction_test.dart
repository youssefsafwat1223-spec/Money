import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';

import '../../harness/egress_test_support.dart';
import '../session/recording_secure_storage.dart';

// Astra A3(d): durable pending slots are structurally required. The production
// construction paths (the unnamed constructor and the platform factory) cannot
// omit them; volatile in-memory pending layers exist only behind the explicitly
// named testing constructor.

const _owner = 'uid-a';

PendingEnableRecord _record() => const PendingEnableRecord(
      ownerUid: _owner,
      transitionGeneration: 4,
      reservedVersion: 3,
      localOperationId: 'op-1',
    );

String _src(String path) => File(path).readAsStringSync();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('production platform factory: a rebuilt store keeps the pending denial',
      () async {
    final dir = Directory.systemTemp.createTempSync('egress_store_ctor_');
    RecordingSecureStorage().install();
    try {
      CloudEgressStore build() => CloudEgressStore.platform(
            storage: const FlutterSecureStorage(),
            directory: () async => dir,
            useNativeDefault: false,
          );
      final first = build();
      final written = await first.beginPending(_record());
      expect(written.all, isTrue);
      // A new process: a new store over the same persisted bytes.
      final rebuilt = await build().readPending();
      expect(rebuilt.unreadable, isFalse);
      expect(rebuilt.blocks(_owner), isTrue);
      expect(rebuilt.agreed(_owner), isNotNull);
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test('the explicitly named testing constructor gives volatile pending layers',
      () async {
    final a = CloudEgressStore.forTesting(secure: MemorySlot(), file: MemorySlot());
    expect((await a.readPending()).blocks(_owner), isFalse);
    await a.beginPending(_record());
    expect((await a.readPending()).blocks(_owner), isTrue);
    // Volatile: a second testing store over the same egress slots sees nothing.
    final b = CloudEgressStore.forTesting(secure: MemorySlot(), file: MemorySlot());
    expect((await b.readPending()).blocks(_owner), isFalse);
  });

  test('the testing constructor still accepts explicit durable pending slots',
      () async {
    final ps = MemorySlot();
    final pf = MemorySlot();
    final one = CloudEgressStore.forTesting(
        secure: MemorySlot(),
        file: MemorySlot(),
        pendingSecure: ps,
        pendingFile: pf);
    await one.beginPending(_record());
    final two = CloudEgressStore.forTesting(
        secure: MemorySlot(),
        file: MemorySlot(),
        pendingSecure: ps,
        pendingFile: pf);
    expect((await two.readPending()).blocks(_owner), isTrue);
  });

  group('architecture pin: production code cannot omit durable pending storage',
      () {
    final gate = _src('lib/core/privacy/cloud_egress_gate.dart');

    test('the unnamed constructor requires both pending slots', () {
      final ctor = RegExp(r'CloudEgressStore\(\{([^}]*)\}\)').firstMatch(gate);
      expect(ctor, isNotNull);
      final params = ctor!.group(1)!;
      expect(params, contains('required DurableSlot pendingSecure'));
      expect(params, contains('required DurableSlot pendingFile'));
      expect(params, isNot(contains('DurableSlot? pendingSecure')));
      expect(params, isNot(contains('DurableSlot? pendingFile')));
    });

    test('a volatile slot is built only inside the testing constructor', () {
      final uses = RegExp(r'_VolatileSlot\(\)').allMatches(gate).toList();
      expect(uses, isNotEmpty);
      final testing = gate.indexOf('CloudEgressStore.forTesting(');
      expect(testing, greaterThan(0));
      final testingEnd = gate.indexOf(';', gate.indexOf('_pendingFile', testing));
      for (final m in uses) {
        expect(m.start, greaterThan(testing));
        expect(m.start, lessThan(testingEnd + 1));
      }
      expect(gate.substring(testing - 40, testing),
          contains('@visibleForTesting'));
    });

    test('no production file constructs a store without both pending slots', () {
      final offenders = <String>[];
      for (final f in Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))) {
        final text = f.readAsStringSync();
        if (text.contains('CloudEgressStore.forTesting')) {
          if (!f.path.endsWith('cloud_egress_gate.dart')) {
            offenders.add('${f.path}: uses forTesting');
          }
        }
        for (final m in RegExp(r'CloudEgressStore\(').allMatches(text)) {
          final end = text.indexOf(');', m.start);
          final call = text.substring(m.start, end);
          // The constructor's own declaration (parameters are `required`).
          if (call.contains('required DurableSlot pendingSecure')) continue;
          if (!call.contains('pendingSecure:') || !call.contains('pendingFile:')) {
            offenders.add(f.path);
          }
        }
      }
      expect(offenders, isEmpty);
    });
  });
}
