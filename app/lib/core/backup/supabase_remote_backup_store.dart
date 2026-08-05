import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import 'remote_backup_state.dart';
import 'remote_backup_store.dart';

// MALI-076n (Phase-6 Batch 3) — the production [RemoteBackupStore] over Supabase
// Storage + the `backups` pointer row. Ownership is server-enforced: the object
// path lives under the user's `<uid>/…` folder (storage RLS) and the pointer row
// is owner-scoped (`own backup all` RLS), so a caller-supplied owner id is never
// authoritative. Maps provider errors into the typed remote taxonomy — no raw
// Supabase message, token, header, or signed URL ever escapes.
class SupabaseRemoteBackupStore implements RemoteBackupStore {
  SupabaseRemoteBackupStore(this._client);

  final supabase.SupabaseClient _client;
  static const _bucket = 'backups';

  @override
  String? get ownerId => _client.auth.currentUser?.id;

  @override
  Future<void> putObject(String path, Uint8List bytes) async {
    try {
      await _client.storage.from(_bucket).uploadBinary(
            path,
            bytes,
            fileOptions: const supabase.FileOptions(
              upsert: true,
              contentType: 'application/octet-stream',
            ),
          );
    } on supabase.StorageException catch (e) {
      throw RemoteBackupException(
        e.statusCode == '413'
            ? RemoteBackupErrorKind.quotaExceeded
            : RemoteBackupErrorKind.uploadFailed,
      );
    }
  }

  @override
  Future<int?> objectSize(String path) async {
    final slash = path.lastIndexOf('/');
    final dir = path.substring(0, slash);
    final name = path.substring(slash + 1);
    try {
      final files = await _client.storage.from(_bucket).list(path: dir);
      for (final f in files) {
        if (f.name == name) {
          final size = f.metadata?['size'];
          if (size is int) return size;
          if (size is num) return size.toInt();
          return null;
        }
      }
      return null;
    } on supabase.StorageException {
      return null;
    }
  }

  @override
  Future<Uint8List> getObject(String path, {required int maxBytes}) async {
    try {
      final bytes = await _client.storage.from(_bucket).download(path);
      if (bytes.length > maxBytes) {
        throw const RemoteBackupException(
            RemoteBackupErrorKind.downloadIntegrityFailed);
      }
      return bytes;
    } on supabase.StorageException catch (e) {
      throw RemoteBackupException(e.statusCode == '404'
          ? RemoteBackupErrorKind.remoteObjectMissing
          : RemoteBackupErrorKind.downloadFailed);
    }
  }

  @override
  Future<void> deleteObject(String path) async {
    try {
      await _client.storage.from(_bucket).remove([path]);
    } on supabase.StorageException {
      throw const RemoteBackupException(RemoteBackupErrorKind.deletionFailed);
    }
  }

  @override
  Future<void> commitGeneration(
    RemoteBackupMetadata m, {
    String? expectedPrevGenerationId,
  }) async {
    final owner = ownerId;
    if (owner == null) {
      throw const RemoteBackupException(
          RemoteBackupErrorKind.authenticationRequired);
    }
    // Compare-and-set on the current committed generation (the owner RLS scopes
    // the row to this user). A server-atomic CAS RPC is a documented follow-up;
    // this read-check-then-write prevents the common lost-update and detects a
    // concurrent device that already advanced the generation.
    final current = await readCurrentGeneration();
    if (current?.generationId != expectedPrevGenerationId) {
      throw const RemoteBackupException(RemoteBackupErrorKind.staleGeneration);
    }
    final now = DateTime.now().toUtc().toIso8601String();
    try {
      await _client.from('backups').upsert({
        'user_id': owner,
        'blob_path': m.objectPath,
        'blob_version': m.envelopeVersion,
        'size_bytes': m.sizeBytes,
        'blob_sha256': m.blobSha256,
        'generation_id': m.generationId,
        'operation_id': m.operationId,
        'status': m.status,
        'committed_at': now,
        'updated_at': now,
      });
    } on supabase.PostgrestException {
      throw const RemoteBackupException(
          RemoteBackupErrorKind.storageUnavailable);
    }
  }

  @override
  Future<RemoteBackupMetadata?> readCurrentGeneration() async {
    final owner = ownerId;
    if (owner == null) return null;
    try {
      final row = await _client
          .from('backups')
          .select()
          .eq('user_id', owner)
          .maybeSingle();
      if (row == null || row['generation_id'] == null) return null;
      return RemoteBackupMetadata(
        generationId: row['generation_id'] as String,
        objectPath: row['blob_path'] as String,
        envelopeVersion: (row['blob_version'] as int?) ?? 3,
        sizeBytes: (row['size_bytes'] as int?) ?? 0,
        blobSha256: (row['blob_sha256'] as String?) ?? '',
        operationId: (row['operation_id'] as String?) ?? '',
        status: (row['status'] as String?) ?? 'committed',
      );
    } on supabase.PostgrestException {
      return null;
    }
  }

  @override
  Future<void> clearGeneration() async {
    final owner = ownerId;
    if (owner == null) return;
    try {
      await _client.from('backups').delete().eq('user_id', owner);
    } on supabase.PostgrestException {
      throw const RemoteBackupException(RemoteBackupErrorKind.deletionFailed);
    }
  }
}
