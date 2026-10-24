import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';

import '../../harness/egress_test_support.dart';
import '../session/recording_secure_storage.dart';

// N-E: the durable Dart-side pending denial of an explicit Cloud enable. Real
// temp-file slots and a real secure-storage-backed slot (the platform double is
// the recording in-memory storage), one per Dart persistence layer. Nothing here
// touches a network or a native channel.

const kOwner = 'uid-a';
const kOther = 'uid-b';

class Flaky implements DurableSlot {
  Flaky(this.inner);
  final DurableSlot inner;
  bool failReads = false;
  bool failWrites = false;
  bool dropWrites = false; // the write "succeeds" but nothing lands (no read-back)
  int writes = 0;

  @override
  Future<SlotRead> read() async => failReads
      ? const SlotRead(SlotStatus.unreadable)
      : inner.read();

  @override
  Future<void> write(String value) async {
    if (failWrites) throw StateError('write failed');
    writes++;
    if (!dropWrites) await inner.write(value);
  }

  @override
  Future<void> delete() => inner.delete();
}

PendingEnableRecord rec({
  String owner = kOwner,
  int generation = 4,
  int version = 3,
  String op = 'op-1',
  CloudEgressEnableBinding? binding,
}) =>
    PendingEnableRecord(
      ownerUid: owner,
      transitionGeneration: generation,
      reservedVersion: version,
      localOperationId: op,
      binding: binding,
    );

const binding = CloudEgressEnableBinding(
  operationId: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  transitionGeneration: 4,
  reservedVersion: 3,
  ownerGeneration: 7,
  ownerEpoch: 2,
);

CloudEgressRecord egress(EgressState s, int g, [int v = 3, String o = kOwner]) =>
    CloudEgressRecord(
        state: s, ownerUid: o, transitionGeneration: g, reservedVersion: v);

class Fixture {
  Fixture._();
  late Directory dir;
  late RecordingSecureStorage secureStorage;
  late Flaky pendingSecure;
  late Flaky pendingFile;
  late Flaky secure;
  late Flaky file;
  late CloudEgressGate gate;
  String owner = kOwner;

  CloudEgressStore store() => CloudEgressStore(
        secure: secure,
        file: file,
        pendingSecure: pendingSecure,
        pendingFile: pendingFile,
      );

  static Future<Fixture> create() async {
    final f = Fixture._();
    f.dir = Directory.systemTemp.createTempSync('pending_enable_');
    f.secureStorage = RecordingSecureStorage().install();
    const storage = FlutterSecureStorage();
    f.pendingSecure = Flaky(SecureStorageSlot(storage, 'qirsh.test.pending'));
    f.pendingFile = Flaky(FileSlot(() async => f.dir, 'pending.json'));
    f.secure = Flaky(SecureStorageSlot(storage, 'qirsh.test.egress'));
    f.file = Flaky(FileSlot(() async => f.dir, 'egress.json'));
    f.gate = f.newGate();
    return f;
  }

  CloudEgressGate newGate() => CloudEgressGate(
        store: store(),
        activeOwner: () async => owner,
        resolved: true,
        nativeInflight: (_) async => (count: 0, latestDeadline: null),
      );

  /// A fresh process: new gate and store objects over the SAME persisted bytes.
  CloudEgressGate reload() => gate = newGate();

  Future<void> seedOn([String o = kOwner, int g = 3]) async {
    final body = jsonEncode({
      'v': 1,
      'records': {o: egress(EgressState.on, g, 2, o).toJson()},
    });
    await secure.inner.write(body);
    await file.inner.write(body);
  }

  void dispose() => dir.deleteSync(recursive: true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Fixture f;
  setUp(() async => f = await Fixture.create());
  tearDown(() => f.dispose());

  group('permits / admit / refresh deny while any pending is present', () {
    test('no pending: a durable ON record permits (control)', () async {
      await f.seedOn();
      expect(await f.gate.permits(), isTrue);
      await f.gate.admit().then(f.gate.release);
    });

    for (final layer in ['secure', 'file']) {
      test('pending in ONLY the $layer layer denies permits, admit and refresh',
          () async {
        await f.seedOn();
        final w = await f.gate.beginPendingEnable(rec());
        expect(w.all, isTrue);
        // Remove it from one layer: the other still denies.
        final keep = layer == 'secure' ? f.pendingSecure : f.pendingFile;
        final drop = layer == 'secure' ? f.pendingFile : f.pendingSecure;
        await drop.inner.write(jsonEncode({'v': 1, 'pending': {}}));
        expect((await keep.read()).status, SlotStatus.value);
        f.reload();
        expect(await f.gate.permits(), isFalse);
        await expectLater(
            f.gate.admit(), throwsA(isA<EgressDeniedException>()));
        await f.gate.refresh();
        expect(f.gate.permitsNetworkSync, isFalse);
      });
    }

    for (final layer in ['secure', 'file']) {
      test('unreadable $layer pending layer denies (never treated as absent)',
          () async {
        await f.seedOn();
        (layer == 'secure' ? f.pendingSecure : f.pendingFile).failReads = true;
        expect(await f.gate.permits(), isFalse);
        await expectLater(
            f.gate.admit(), throwsA(isA<EgressDeniedException>()));
      });

      test('corrupt $layer pending layer denies', () async {
        await f.seedOn();
        await (layer == 'secure' ? f.pendingSecure : f.pendingFile)
            .inner
            .write('{not json');
        expect(await f.gate.permits(), isFalse);
        await expectLater(
            f.gate.admit(), throwsA(isA<EgressDeniedException>()));
      });
    }

    test('conflicting pending records in the two layers deny', () async {
      await f.seedOn();
      await f.pendingSecure.inner.write(jsonEncode({
        'v': 1,
        'pending': {kOwner: rec(op: 'one').toJson()},
      }));
      await f.pendingFile.inner.write(jsonEncode({
        'v': 1,
        'pending': {kOwner: rec(op: 'two', generation: 9).toJson()},
      }));
      expect(await f.gate.permits(), isFalse);
      final readout = await f.gate.readPending();
      expect(readout.blocks(kOwner), isTrue);
      expect(readout.agreed(kOwner), isNull,
          reason: 'conflicting records have no agreed operation');
    });

    test('fresh-process reload still denies; clearing restores permission',
        () async {
      await f.seedOn();
      expect((await f.gate.beginPendingEnable(rec())).all, isTrue);
      f.reload();
      expect(await f.gate.permits(), isFalse);
      expect((await f.gate.clearPendingEnable(rec())).all, isTrue);
      f.reload();
      expect(await f.gate.permits(), isTrue);
    });

    test('another owner\'s pending does not deny this owner but is preserved',
        () async {
      await f.seedOn();
      expect((await f.gate.beginPendingEnable(rec(owner: kOther))).all, isTrue);
      expect(await f.gate.permits(), isTrue);
      expect((await f.gate.beginPendingEnable(rec())).all, isTrue);
      expect(await f.gate.permits(), isFalse);
      expect((await f.gate.clearPendingEnable(rec())).all, isTrue);
      final readout = await f.gate.readPending();
      expect(readout.blocks(kOther), isTrue,
          reason: 'clearing A never drops B\'s pending denial');
      expect(readout.blocks(kOwner), isFalse);
    });

    test('an in-process freeze denies synchronously before any durable write',
        () async {
      await f.seedOn();
      await f.gate.refresh();
      expect(f.gate.permitsNetworkSync, isTrue);
      final epoch = f.gate.epoch;
      f.gate.freezeEnable(kOwner);
      expect(f.gate.permitsNetworkSync, isFalse);
      expect(f.gate.epoch, greaterThan(epoch));
      expect(await f.gate.permits(), isFalse);
    });

    test('account-control and the signed-out scope are not blocked by it',
        () async {
      await f.seedOn();
      await f.gate.beginPendingEnable(rec());
      f.owner = '';
      expect(await f.gate.permits(), isFalse, reason: 'no ON record for ""');
      f.owner = kOwner;
      final control = await f.gate.runAccountControl(
          AccountControlOp.signIn, () async => 1);
      expect(control, 1);
    });
  });

  group('per-layer write and read-back', () {
    for (final layer in ['secure', 'file']) {
      test('a failed $layer pending write is reported and ON is not allowed',
          () async {
        await f.seedOn();
        (layer == 'secure' ? f.pendingSecure : f.pendingFile).failWrites = true;
        final w = await f.gate.beginPendingEnable(rec());
        expect(w.all, isFalse);
        expect(layer == 'secure' ? w.secure : w.file, isFalse);
        expect(layer == 'secure' ? w.file : w.secure, isTrue);
        // The durable denial that did land still denies.
        f.reload();
        expect(await f.gate.permits(), isFalse);
      });

      test('a $layer write that silently did not land fails read-back',
          () async {
        (layer == 'secure' ? f.pendingSecure : f.pendingFile).dropWrites = true;
        final w = await f.gate.beginPendingEnable(rec());
        expect(w.all, isFalse);
      });

      test('a corrupt $layer pending layer is never overwritten by a begin',
          () async {
        final slot = layer == 'secure' ? f.pendingSecure : f.pendingFile;
        await slot.inner.write('garbage');
        final w = await f.gate.beginPendingEnable(rec());
        expect(w.all, isFalse);
        expect((await slot.inner.read()).raw, 'garbage');
      });
    }

    test('a begin never adopts an existing pending of the same owner',
        () async {
      expect((await f.gate.beginPendingEnable(rec())).all, isTrue);
      final w = await f.gate.beginPendingEnable(rec(op: 'op-2', generation: 5));
      expect(w.all, isFalse);
      final agreed = (await f.gate.readPending()).agreed(kOwner);
      expect(agreed!.localOperationId, 'op-1');
    });

    test('bind replaces only the exact record, per layer, with read-back',
        () async {
      final base = rec();
      await f.gate.beginPendingEnable(base);
      final bound = base.bound(binding);
      expect((await f.gate.bindPendingEnable(from: base, to: bound)).all,
          isTrue);
      expect((await f.gate.readPending()).agreed(kOwner), bound);
      // A stale caller holding the unbound record cannot rebind.
      final other = base.bound(const CloudEgressEnableBinding(
          operationId: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
          transitionGeneration: 4,
          reservedVersion: 3,
          ownerGeneration: 7,
          ownerEpoch: 2));
      expect((await f.gate.bindPendingEnable(from: base, to: other)).all,
          isFalse);
      expect((await f.gate.readPending()).agreed(kOwner), bound);
    });

    test('clear removes only the exact operation; a newer one is untouched',
        () async {
      final newer = rec(op: 'newer', generation: 9, version: 8);
      await f.gate.beginPendingEnable(newer);
      final r = await f.gate.clearPendingEnable(rec());
      expect(r.all, isTrue, reason: 'ours is not there: nothing of ours remains');
      expect((await f.gate.readPending()).agreed(kOwner), newer,
          reason: 'the newer operation still denies');
      expect(await f.gate.permits(), isFalse);
    });

    for (final layer in ['secure', 'file']) {
      test('partial clear (the $layer layer fails) keeps denying', () async {
        await f.seedOn();
        await f.gate.beginPendingEnable(rec());
        (layer == 'secure' ? f.pendingSecure : f.pendingFile).failWrites = true;
        final r = await f.gate.clearPendingEnable(rec());
        expect(r.all, isFalse);
        f.reload();
        expect(await f.gate.permits(), isFalse);
        expect((await f.gate.readPending()).blocks(kOwner), isTrue);
      });
    }

    test('clearing drops the in-process marker only after read-back proves it',
        () async {
      await f.seedOn();
      f.gate.freezeEnable(kOwner);
      await f.gate.beginPendingEnable(rec());
      f.pendingFile.failWrites = true;
      await f.gate.clearPendingEnable(rec());
      await f.gate.refresh();
      expect(f.gate.permitsNetworkSync, isFalse);
      f.pendingFile.failWrites = false;
      expect((await f.gate.clearPendingEnable(rec())).all, isTrue);
      await f.gate.refresh();
      expect(f.gate.permitsNetworkSync, isTrue);
    });
  });

  group('Dart-only ON write', () {
    test('writes ON to the two Dart layers only, with read-back', () async {
      var nativeWrites = 0;
      final store = CloudEgressStore(
        secure: f.secure,
        file: f.file,
        pendingSecure: f.pendingSecure,
        pendingFile: f.pendingFile,
        native: NativeEgressSlot(
            read: (_) async => null, write: (_) async => nativeWrites++),
      );
      final gate = CloudEgressGate(
          store: store, activeOwner: () async => kOwner, resolved: true);
      final r = await gate.writeDartOn(egress(EgressState.on, 5));
      expect(r.all, isTrue);
      expect(nativeWrites, 0, reason: 'native ON is the native phase\'s job');
      final layers = await store.readOwnerLayers(kOwner);
      expect(layers.records.map((e) => e.state).toSet(), {EgressState.on});
    });

    test('preserves other owners\' records in the same layer', () async {
      await f.seedOn(kOther, 2);
      final r = await f.gate.writeDartOn(egress(EgressState.on, 5));
      expect(r.all, isTrue);
      final readout = await f.gate.store.read(owner: kOther);
      expect(readout.records[kOther]!.state, EgressState.on);
      expect(readout.records[kOwner]!.transitionGeneration, 5);
    });

    for (final layer in ['secure', 'file']) {
      test('a $layer ON write failure is reported per layer', () async {
        (layer == 'secure' ? f.secure : f.file).failWrites = true;
        final r = await f.gate.writeDartOn(egress(EgressState.on, 5));
        expect(r.all, isFalse);
        expect(layer == 'secure' ? r.secure : r.file, isFalse);
      });

      test('a corrupt $layer egress layer is not overwritten by ON', () async {
        final slot = layer == 'secure' ? f.secure : f.file;
        await slot.inner.write('garbage');
        final r = await f.gate.writeDartOn(egress(EgressState.on, 5));
        expect(r.all, isFalse);
        expect((await slot.inner.read()).raw, 'garbage');
      });
    }

    test('restrictDartLayers writes OFF only where the written ON is held',
        () async {
      await f.gate.writeDartOn(egress(EgressState.on, 5));
      // A newer generation in one layer is never downgraded.
      await f.file.inner.write(jsonEncode({
        'v': 1,
        'records': {kOwner: egress(EgressState.on, 8, 9).toJson()},
      }));
      final r = await f.gate.restrictDartLayers(egress(EgressState.on, 5));
      expect(r.all, isTrue);
      final secure = await f.secure.inner.read();
      expect(secure.raw, contains('"OFF"'));
      final file = await f.file.inner.read();
      expect(file.raw, contains('"ON"'));
      expect(file.raw, contains('"transition_generation":8'));
    });
  });

  group('generation allocation', () {
    test('is one above the highest readable layer, native included', () async {
      await f.seedOn(kOwner, 3);
      final gate = CloudEgressGate(
        store: CloudEgressStore(
          secure: f.secure,
          file: f.file,
          pendingSecure: f.pendingSecure,
          pendingFile: f.pendingFile,
          native: NativeEgressSlot(
              read: (_) async => egress(EgressState.off, 11),
              write: (_) async {}),
        ),
        activeOwner: () async => kOwner,
        resolved: true,
      );
      expect(await gate.allocateEnableGeneration(kOwner), 12);
    });

    test('an unreadable layer refuses to allocate', () async {
      f.file.failReads = true;
      await expectLater(f.gate.allocateEnableGeneration(kOwner),
          throwsA(isA<EgressWriteFailedException>()));
    });
  });

  test('platform store keys do not collide with the egress record keys', () {
    expect(CloudEgressStore.kPendingSecureKey,
        isNot(CloudEgressStore.kSecureKey));
    expect(CloudEgressStore.kPendingFileName,
        isNot(CloudEgressStore.kFileName));
    expect(CloudEgressStore.kPendingSecureKey.startsWith('qirsh.'), isTrue,
        reason: 'the session wipe keeps qirsh.-prefixed keys');
  });

  test('MemorySlot default pending slots exist for fixtures built without them',
      () async {
    final plain = CloudEgressStore.forTesting(secure: MemorySlot(), file: MemorySlot());
    expect((await plain.readPending()).blocks(kOwner), isFalse);
  });
}
