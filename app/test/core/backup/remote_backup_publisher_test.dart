import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backup/remote_backup_state.dart';
import 'package:money_companion/core/backup/remote_backup_store.dart';

// MALI-076n §5/§7/§13 — safe generation publication + verified download.
class FakeRemoteBackupStore implements RemoteBackupStore {
  FakeRemoteBackupStore({this.ownerId = 'user-A'});

  @override
  String? ownerId;

  final Map<String, Uint8List> objects = {};
  RemoteBackupMetadata? _current;

  // failure injection
  bool failPut = false;
  bool truncateUpload = false;
  bool failCommit = false;
  int putCalls = 0;
  int deleteCalls = 0;
  int commitCalls = 0;

  @override
  Future<void> putObject(String path, Uint8List bytes) async {
    putCalls++;
    if (failPut) {
      throw const RemoteBackupException(RemoteBackupErrorKind.uploadFailed);
    }
    objects[path] = truncateUpload
        ? Uint8List.fromList(bytes.sublist(0, bytes.length ~/ 2))
        : bytes;
  }

  @override
  Future<int?> objectSize(String path) async => objects[path]?.length;

  @override
  Future<Uint8List> getObject(String path, {required int maxBytes}) async {
    final b = objects[path];
    if (b == null) {
      throw const RemoteBackupException(RemoteBackupErrorKind.remoteObjectMissing);
    }
    if (b.length > maxBytes) {
      throw const RemoteBackupException(
          RemoteBackupErrorKind.downloadIntegrityFailed);
    }
    return b;
  }

  @override
  Future<void> deleteObject(String path) async {
    deleteCalls++;
    objects.remove(path);
  }

  @override
  Future<void> commitGeneration(RemoteBackupMetadata m,
      {String? expectedPrevGenerationId}) async {
    commitCalls++;
    if (failCommit) {
      throw const RemoteBackupException(RemoteBackupErrorKind.uploadFailed);
    }
    if (expectedPrevGenerationId != _current?.generationId) {
      throw const RemoteBackupException(RemoteBackupErrorKind.staleGeneration);
    }
    _current = m;
  }

  @override
  Future<RemoteBackupMetadata?> readCurrentGeneration() async => _current;

  @override
  Future<void> clearGeneration() async => _current = null;
}

void main() {
  final blobA = Uint8List.fromList(List<int>.generate(2000, (i) => i % 251));
  final blobB = Uint8List.fromList(List<int>.generate(2500, (i) => (i * 3) % 251));

  Future<RemoteBackupMetadata> commitFirst(
      RemoteBackupPublisher pub) =>
      pub.publish(
          blob: blobA,
          envelopeVersion: 3,
          generationId: 'gen-1',
          operationId: 'op-1');

  group('safe publication', () {
    test('a clean publish uploads to a unique path, verifies, and commits', () async {
      final store = FakeRemoteBackupStore();
      final pub = RemoteBackupPublisher(store);
      final meta = await commitFirst(pub);
      expect(meta.generationId, 'gen-1');
      expect(meta.objectPath, 'user-A/g/gen-1.enc');
      expect(meta.sizeBytes, blobA.length);
      expect(meta.blobSha256, sha256Hex(blobA));
      expect((await store.readCurrentGeneration())!.generationId, 'gen-1');
    });

    test('an interrupted upload NEVER replaces the current committed backup',
        () async {
      final store = FakeRemoteBackupStore();
      final pub = RemoteBackupPublisher(store);
      await commitFirst(pub); // gen-1 is current
      store.failPut = true;
      await expectLater(
        pub.publish(blob: blobB, envelopeVersion: 3, generationId: 'gen-2', operationId: 'op-2'),
        throwsA(isA<RemoteBackupException>()),
      );
      // gen-1 remains current + intact.
      expect((await store.readCurrentGeneration())!.generationId, 'gen-1');
      expect(store.objects['user-A/g/gen-1.enc'], blobA);
    });

    test('a size-mismatched upload fails verification, cleans up, keeps current',
        () async {
      final store = FakeRemoteBackupStore();
      final pub = RemoteBackupPublisher(store);
      await commitFirst(pub);
      store.truncateUpload = true;
      await expectLater(
        pub.publish(blob: blobB, envelopeVersion: 3, generationId: 'gen-2', operationId: 'op-2'),
        throwsA(predicate((e) =>
            e is RemoteBackupException &&
            e.kind == RemoteBackupErrorKind.uploadVerificationFailed)),
      );
      expect((await store.readCurrentGeneration())!.generationId, 'gen-1');
      expect(store.objects.containsKey('user-A/g/gen-2.enc'), isFalse); // cleaned
    });

    test('a failed pointer commit leaves the previous generation current', () async {
      final store = FakeRemoteBackupStore();
      final pub = RemoteBackupPublisher(store);
      await commitFirst(pub);
      store.failCommit = true;
      await expectLater(
        pub.publish(blob: blobB, envelopeVersion: 3, generationId: 'gen-2', operationId: 'op-2'),
        throwsA(isA<RemoteBackupException>()),
      );
      expect((await store.readCurrentGeneration())!.generationId, 'gen-1');
    });

    test('the previous object is retired only AFTER the new pointer commits',
        () async {
      final store = FakeRemoteBackupStore();
      final pub = RemoteBackupPublisher(store);
      await commitFirst(pub);
      await pub.publish(blob: blobB, envelopeVersion: 3, generationId: 'gen-2', operationId: 'op-2');
      expect((await store.readCurrentGeneration())!.generationId, 'gen-2');
      expect(store.objects.containsKey('user-A/g/gen-1.enc'), isFalse); // retired
      expect(store.objects.containsKey('user-A/g/gen-2.enc'), isTrue);
    });

    test('unauthenticated publish is authenticationRequired', () async {
      final store = FakeRemoteBackupStore(ownerId: null);
      final pub = RemoteBackupPublisher(store);
      await expectLater(
        commitFirst(pub),
        throwsA(predicate((e) =>
            e is RemoteBackupException &&
            e.kind == RemoteBackupErrorKind.authenticationRequired)),
      );
    });
  });

  group('idempotency & concurrency (lost response, CAS)', () {
    test('replaying the SAME generation returns the committed result, no dup', () async {
      final store = FakeRemoteBackupStore();
      final pub = RemoteBackupPublisher(store);
      await commitFirst(pub);
      final putsAfterFirst = store.putCalls;
      // Lost-response retry: same generationId.
      final again = await pub.publish(
          blob: blobA, envelopeVersion: 3, generationId: 'gen-1', operationId: 'op-1');
      expect(again.generationId, 'gen-1');
      expect(store.putCalls, putsAfterFirst); // no duplicate upload
    });

    test('a stale-generation commit is rejected (CAS)', () async {
      final store = FakeRemoteBackupStore();
      final pub = RemoteBackupPublisher(store);
      await commitFirst(pub); // current = gen-1
      // Simulate another device committing gen-X in the meantime.
      await store.commitGeneration(
        const RemoteBackupMetadata(
            generationId: 'gen-X',
            objectPath: 'user-A/g/gen-X.enc',
            envelopeVersion: 3,
            sizeBytes: 10,
            blobSha256: 'x',
            operationId: 'op-X'),
        expectedPrevGenerationId: 'gen-1',
      );
      // Our publisher still thinks prev is gen-1 → but the store now expects gen-X.
      // A direct commit with the wrong expected-prev is a staleGeneration.
      await expectLater(
        store.commitGeneration(
          const RemoteBackupMetadata(
              generationId: 'gen-2',
              objectPath: 'p',
              envelopeVersion: 3,
              sizeBytes: 1,
              blobSha256: 'y',
              operationId: 'op-2'),
          expectedPrevGenerationId: 'gen-1',
        ),
        throwsA(predicate((e) =>
            e is RemoteBackupException &&
            e.kind == RemoteBackupErrorKind.staleGeneration)),
      );
    });
  });

  group('verified download', () {
    test('a matching object downloads', () async {
      final store = FakeRemoteBackupStore();
      final pub = RemoteBackupPublisher(store);
      final meta = await commitFirst(pub);
      final bytes = await pub.downloadVerified(meta);
      expect(bytes, blobA);
    });

    test('a size mismatch is a downloadIntegrityFailed', () async {
      final store = FakeRemoteBackupStore();
      final pub = RemoteBackupPublisher(store);
      final meta = await commitFirst(pub);
      // Corrupt the stored object.
      store.objects[meta.objectPath] = Uint8List.fromList([1, 2, 3]);
      await expectLater(
        pub.downloadVerified(meta),
        throwsA(predicate((e) =>
            e is RemoteBackupException &&
            e.kind == RemoteBackupErrorKind.downloadIntegrityFailed)),
      );
    });

    test('a hash mismatch (same size) is a downloadIntegrityFailed', () async {
      final store = FakeRemoteBackupStore();
      final pub = RemoteBackupPublisher(store);
      final meta = await commitFirst(pub);
      final tampered = Uint8List.fromList(blobA)..[0] ^= 0xFF;
      store.objects[meta.objectPath] = tampered;
      await expectLater(
        pub.downloadVerified(meta),
        throwsA(predicate((e) =>
            e is RemoteBackupException &&
            e.kind == RemoteBackupErrorKind.downloadIntegrityFailed)),
      );
    });

    test('an oversized declared size is rejected before download', () async {
      final pub = RemoteBackupPublisher(FakeRemoteBackupStore(), maxBlobBytes: 100);
      const meta = RemoteBackupMetadata(
          generationId: 'g',
          objectPath: 'p',
          envelopeVersion: 3,
          sizeBytes: 999999,
          blobSha256: 'x',
          operationId: 'o');
      await expectLater(
        pub.downloadVerified(meta),
        throwsA(isA<RemoteBackupException>()),
      );
    });
  });
}
