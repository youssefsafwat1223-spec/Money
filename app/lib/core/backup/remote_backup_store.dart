import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'remote_backup_state.dart';

// MALI-076n / MALI-014 (Phase-6 Batch 3) — safe remote-backup object lifecycle.
// A storage abstraction (injectable for deterministic tests) plus the
// publication + verified-download orchestration: an interrupted upload never
// replaces the last valid backup, and every download is size/hash-verified
// before any decryption.

/// Server-committed backup pointer metadata. Owner is derived SERVER-side; this
/// contains NO passphrase, key, nonce, plaintext, or financial content
/// (MALI-076n §8). [blobSha256] is a transport/integrity hash of the ENCRYPTED
/// blob — it never replaces the v3 AEAD authentication.
class RemoteBackupMetadata {
  const RemoteBackupMetadata({
    required this.generationId,
    required this.objectPath,
    required this.envelopeVersion,
    required this.sizeBytes,
    required this.blobSha256,
    required this.operationId,
    this.status = 'committed',
  });

  final String generationId;
  final String objectPath;
  final int envelopeVersion;
  final int sizeBytes;
  final String blobSha256;
  final String operationId;
  final String status;
}

/// Abstraction over remote object storage + the current-generation pointer.
/// Implementations must enforce server-derived ownership (a caller-supplied owner
/// id is never authoritative) — see [ownerId].
abstract class RemoteBackupStore {
  /// The authenticated owner id (server-derived); null when unauthenticated.
  String? get ownerId;

  Future<void> putObject(String path, Uint8List bytes);

  /// The stored object's size, or null if it is absent.
  Future<int?> objectSize(String path);

  /// Download an object, aborting if it exceeds [maxBytes] (never buffers an
  /// unbounded remote object).
  Future<Uint8List> getObject(String path, {required int maxBytes});

  Future<void> deleteObject(String path);

  /// Commit the current-generation pointer. When [expectedPrevGenerationId] is
  /// provided it is a compare-and-set: a mismatch throws
  /// [RemoteBackupException] with [RemoteBackupErrorKind.staleGeneration].
  Future<void> commitGeneration(
    RemoteBackupMetadata metadata, {
    String? expectedPrevGenerationId,
  });

  Future<RemoteBackupMetadata?> readCurrentGeneration();

  Future<void> clearGeneration();
}

/// SHA-256 of [bytes] as lowercase hex.
String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

/// Orchestrates safe publication + verified download over a [RemoteBackupStore].
class RemoteBackupPublisher {
  RemoteBackupPublisher(this._store, {int maxBlobBytes = 96 * 1024 * 1024})
      : _maxBlobBytes = maxBlobBytes;

  final RemoteBackupStore _store;
  final int _maxBlobBytes;

  String objectPathFor(String owner, String generationId) =>
      '$owner/g/$generationId.enc';

  /// Publish a new generation of the encrypted [blob].
  ///
  /// Contract (MALI-076n §5): each generation uses a UNIQUE per-generation object
  /// path (never the previous committed object), so an interrupted upload can
  /// only create a new orphan and can never replace the last valid backup. The
  /// upload is size-verified; the pointer commit is a compare-and-set on the
  /// previous generation; the old object is retired ONLY after the new pointer
  /// commits. [generationId]/[operationId] make a lost-response retry idempotent:
  /// if the committed generation already equals [generationId], the existing
  /// result is returned with no duplicate upload.
  Future<RemoteBackupMetadata> publish({
    required Uint8List blob,
    required int envelopeVersion,
    required String generationId,
    required String operationId,
  }) async {
    final owner = _store.ownerId;
    if (owner == null || owner.isEmpty) {
      throw const RemoteBackupException(
          RemoteBackupErrorKind.authenticationRequired);
    }
    if (blob.length > _maxBlobBytes) {
      throw const RemoteBackupException(RemoteBackupErrorKind.uploadFailed);
    }

    // Lost-response idempotency: is this exact generation already committed?
    final current = await _store.readCurrentGeneration();
    if (current != null && current.generationId == generationId) {
      return current;
    }

    final objectPath = objectPathFor(owner, generationId);
    // 1. Upload to the unique per-generation path (never overwrites current).
    await _store.putObject(objectPath, blob);
    // 2. Verify the uploaded byte count; a mismatch keeps the prior generation
    //    current and cleans up the bad object.
    final size = await _store.objectSize(objectPath);
    if (size != blob.length) {
      await _safeDelete(objectPath);
      throw const RemoteBackupException(
          RemoteBackupErrorKind.uploadVerificationFailed);
    }
    final meta = RemoteBackupMetadata(
      generationId: generationId,
      objectPath: objectPath,
      envelopeVersion: envelopeVersion,
      sizeBytes: blob.length,
      blobSha256: sha256Hex(blob),
      operationId: operationId,
    );
    // 3. Atomically commit the pointer (CAS on the previous generation).
    await _store.commitGeneration(meta,
        expectedPrevGenerationId: current?.generationId);
    // 4. Retire the previous object ONLY after the new pointer is committed.
    if (current != null && current.objectPath != objectPath) {
      await _safeDelete(current.objectPath);
    }
    return meta;
  }

  /// Download + integrity-verify the committed generation BEFORE any decryption
  /// (MALI-076n §7). Enforces the max size and verifies actual byte count + the
  /// encrypted-blob hash. Successful hash verification does NOT bypass the v3
  /// AEAD authentication the caller performs afterward.
  Future<Uint8List> downloadVerified(RemoteBackupMetadata meta) async {
    if (meta.sizeBytes > _maxBlobBytes) {
      throw const RemoteBackupException(
          RemoteBackupErrorKind.downloadIntegrityFailed);
    }
    final bytes = await _store.getObject(meta.objectPath, maxBytes: _maxBlobBytes);
    if (bytes.length != meta.sizeBytes ||
        sha256Hex(bytes) != meta.blobSha256) {
      throw const RemoteBackupException(
          RemoteBackupErrorKind.downloadIntegrityFailed);
    }
    return bytes;
  }

  Future<void> _safeDelete(String path) async {
    // Orphan/previous-object cleanup is best-effort + retryable — a failure here
    // must never fail an otherwise-successful publish or leave the DB at risk.
    try {
      await _store.deleteObject(path);
    } catch (_) {}
  }
}
