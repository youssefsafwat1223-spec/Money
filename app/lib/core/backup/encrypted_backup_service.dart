import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:cryptography/cryptography.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import '../../data/db/app_database.dart';
import '../utils/id_generator.dart';
import 'backup_crypto.dart';
import 'backup_service.dart';
import 'backup_snapshot_builder.dart';
import 'remote_backup_store.dart';
import 'restore_backup_usecase.dart';
import 'supabase_remote_backup_store.dart';

class EncryptedBackupService implements BackupService {
  EncryptedBackupService({
    required AppDatabase database,
    supabase.SupabaseClient? client,
    FlutterSecureStorage? storage,
    BackupCrypto? crypto,
    Future<void> Function()? afterRestore,
  })  : _database = database,
        _client = client ?? supabase.Supabase.instance.client,
        _storage = storage ?? const FlutterSecureStorage(),
        _crypto = crypto ?? BackupCrypto(),
        _afterRestore = afterRestore;

  static const _bucket = 'backups';
  static const _enabledKey = 'backup_enabled';
  static const _saltKey = 'backup_salt';
  static const _recoveryKey = 'backup_recovery_code';
  static const _lastKey = 'backup_last_at';
  static const _localKeyKey = 'backup_local_key';
  static const _keySlotsKey = 'backup_key_slots';
  // MALI-076n — marks a slot set + local content key as the v3 authenticated
  // envelope format. Absent ⇒ a legacy (pre-v3) install that keeps its format.
  static const _envelopeVersionKey = 'backup_envelope_version';

  final AppDatabase _database;
  final supabase.SupabaseClient _client;
  final FlutterSecureStorage _storage;

  // MALI-076n §5 — safe generation-based publication + verified download.
  late final RemoteBackupStore _remoteStore =
      SupabaseRemoteBackupStore(_client);
  late final RemoteBackupPublisher _publisher =
      RemoteBackupPublisher(_remoteStore);
  final BackupCrypto _crypto;
  final Future<void> Function()? _afterRestore;

  @override
  Future<BackupStatus> status() async {
    final enabled = await _storage.read(key: _enabledKey) == '1';
    final lastRaw = await _storage.read(key: _lastKey);
    return BackupStatus(
      enabled: enabled,
      lastBackupAt: lastRaw == null ? null : DateTime.tryParse(lastRaw),
    );
  }

  @override
  Future<bool> hasRemoteBackup() async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) return false;
    try {
      final files = await _client.storage.from(_bucket).list(path: userId);
      return files.any((file) => file.name == 'backup.enc');
    } catch (_) {
      return false;
    }
  }

  @override
  Future<String> enable({required String passphrase}) async {
    final userId = _userId();
    // MALI-076n §6 — v3 uses the passphrase EXACTLY as entered (UTF-8, no trim,
    // no Unicode normalization); whitespace and case are significant.
    final recovery = _generateRecoveryCode();
    final keyBytes = _crypto.randomBytes(32);
    final keySlots = await _crypto.createV3KeySlots(
      contentKey: keyBytes,
      passphrase: passphrase,
      recoveryCode: recovery,
    );
    await _storage.write(key: _enabledKey, value: '1');
    await _storage.write(key: _envelopeVersionKey, value: '3');
    await _storage.write(key: _recoveryKey, value: recovery);
    await _storage.write(key: _keySlotsKey, value: _encodeKeySlots(keySlots));
    await _storage.write(
      key: _localKeyKey,
      value: base64Encode(keyBytes),
    );
    await _storage.delete(key: _saltKey);
    try {
      await backupNow();
      await _client.from('profiles').upsert({
        'id': userId,
        'email': _client.auth.currentUser?.email,
        'auth_method':
            _client.auth.currentSession?.user.appMetadata['provider'],
      });
    } catch (_) {
      await _clearLocalBackupState();
      rethrow;
    }
    return recovery;
  }

  /// MALI-058n — the remote-backup metadata row upserted alongside the upload.
  /// It is built ONLY from the user id, the object path, and blob size/version/
  /// time — never from user_settings or any key material — so it can carry no key
  /// canary. Exposed so a test can assert the actual object, not just the source.
  @visibleForTesting
  static Map<String, dynamic> uploadMetadata({
    required String userId,
    required String path,
    required int blobVersion,
    required int sizeBytes,
    required String updatedAtIso,
  }) =>
      {
        'user_id': userId,
        'blob_path': path,
        'blob_version': blobVersion,
        'size_bytes': sizeBytes,
        'updated_at': updatedAtIso,
      };

  @override
  Future<void> backupNow() async {
    final userId = _userId();
    final enabled = await _storage.read(key: _enabledKey) == '1';
    if (!enabled) return;

    final saltRaw = await _storage.read(key: _saltKey);
    final keyRaw = await _storage.read(key: _localKeyKey);
    final slotsRaw = await _storage.read(key: _keySlotsKey);
    final recoveryRaw = await _storage.read(key: _recoveryKey);
    if (keyRaw == null ||
        ((slotsRaw == null || slotsRaw.isEmpty) && saltRaw == null)) {
      throw const BackupException('النسخ الاحتياطي يحتاج تفعيل جديد.');
    }

    final snapshot = await BackupSnapshotBuilder(_database).build();
    final keyBytes = base64Decode(keyRaw);

    // MALI-076n — current installs write the v3 authenticated envelope, reusing
    // the stored content key + slots (no passphrase needed for a background
    // backup). Pre-v3 installs keep their existing format until re-enable.
    final isV3 = await _storage.read(key: _envelopeVersionKey) == '3';
    if (isV3 && slotsRaw != null && slotsRaw.isNotEmpty) {
      final v3Blob = await _crypto.encryptEnvelopeV3WithContentKey(
        json: snapshot,
        schemaVersion: BackupSnapshotBuilder.currentSchemaVersion,
        contentKey: keyBytes,
        keySlots: _decodeKeySlots(slotsRaw),
      );
      final v3Bytes = v3Blob.toBytes();
      // MALI-076n §5 — publish as a NEW generation: a unique per-generation
      // object path, size-verified upload, compare-and-set pointer commit, then
      // retire the previous object ONLY after the new pointer commits. An
      // interrupted upload can only orphan a new object; the last valid backup is
      // never replaced.
      await _publisher.publish(
        blob: v3Bytes,
        envelopeVersion: v3Blob.version,
        generationId: IdGenerator.uuidV4(),
        operationId: IdGenerator.uuidV4(),
      );
      await _storage.write(
          key: _lastKey, value: DateTime.now().toUtc().toIso8601String());
      return;
    }

    final shouldUpgradeLegacyBackup =
        (slotsRaw == null || slotsRaw.isEmpty) && recoveryRaw != null;
    final blob = shouldUpgradeLegacyBackup
        ? await _crypto.encryptJsonWithRawKey(
            json: snapshot,
            keyBytes: keyBytes,
            keySlots: [
              await _crypto.createKeySlot(
                type: 'recovery',
                secret: recoveryRaw,
                keyBytes: keyBytes,
              ),
            ],
            salt: base64Decode(saltRaw!),
          )
        : slotsRaw == null || slotsRaw.isEmpty
            ? await _crypto.encryptJsonWithKey(
                json: snapshot,
                key: SecretKey(keyBytes),
                salt: base64Decode(saltRaw!),
              )
            : await _crypto.encryptJsonWithRawKey(
                json: snapshot,
                keyBytes: keyBytes,
                keySlots: _decodeKeySlots(slotsRaw),
              );
    if (shouldUpgradeLegacyBackup) {
      await _storage.write(
        key: _keySlotsKey,
        value: _encodeKeySlots(blob.keySlots),
      );
    }
    final bytes = blob.toBytes();
    final path = '$userId/backup.enc';
    try {
      await _client.storage.from(_bucket).uploadBinary(
            path,
            bytes,
            fileOptions: const supabase.FileOptions(
              upsert: true,
              contentType: 'application/octet-stream',
            ),
          );
      final now = DateTime.now().toUtc();
      await _client.from('backups').upsert(uploadMetadata(
        userId: userId,
        path: path,
        blobVersion: blob.version,
        sizeBytes: bytes.length,
        updatedAtIso: now.toIso8601String(),
      ));
      await _storage.write(key: _lastKey, value: now.toIso8601String());
    } on supabase.StorageException catch (error) {
      throw BackupException(backupStorageExceptionMessage(error));
    }
  }

  /// MALI-076n §3 — DISABLE stops future uploads ONLY. It clears local backup
  /// scheduling + keys but deliberately does NOT delete the remote backup, so the
  /// existing backup stays restorable (with its passphrase) and re-enabling makes
  /// a fresh one. Deleting remote data is a SEPARATE, explicit destructive action
  /// ([deleteRemoteBackups]); the two are never silently combined. The local
  /// database is unaffected either way.
  @override
  Future<void> disable() async {
    await _clearLocalBackupState();
  }

  /// MALI-076n §3 — the explicit destructive action: delete the committed remote
  /// backup object + its pointer (and any legacy fixed object). A failed remote
  /// deletion surfaces a typed [RemoteBackupException]; the local database and
  /// local files are never touched.
  Future<void> deleteRemoteBackups() async {
    final generation = await _remoteStore.readCurrentGeneration();
    if (generation != null) {
      await _remoteStore.deleteObject(generation.objectPath);
    }
    final owner = _remoteStore.ownerId;
    if (owner != null) {
      try {
        await _client.storage.from(_bucket).remove(['$owner/backup.enc']);
      } on supabase.StorageException {
        // Legacy object may be absent — that is idempotent success.
      }
    }
    await _remoteStore.clearGeneration();
  }

  @override
  Future<void> restoreFromBackup({required String passphrase}) {
    return restore(passphrase: passphrase);
  }

  Future<void> restore({required String passphrase}) async {
    final userId = _userId();
    // MALI-076n §7 — prefer the committed generation, integrity-verified (size +
    // encrypted-blob hash) BEFORE any decryption. A legacy backup with no
    // generation pointer falls back to the fixed object path (its integrity is
    // still enforced by the v3/legacy envelope authentication below).
    final generation = await _remoteStore.readCurrentGeneration();
    final Uint8List bytes;
    if (generation != null) {
      bytes = await _publisher.downloadVerified(generation);
    } else {
      bytes = await _client.storage.from(_bucket).download('$userId/backup.enc');
    }
    try {
      // MALI-076n §9 — structurally validate the untrusted envelope and enforce
      // resource limits BEFORE any KDF, then decrypt/authenticate — all before
      // the destructive restore below (which itself validates before deleting).
      final blob = EncryptedBackupBlob.fromBytesChecked(bytes);
      List<int>? keyBytes;
      Map<String, dynamic> snapshot;
      if (blob.version >= 3) {
        // v3: the passphrase (or recovery code) unwraps a slot → content key →
        // authenticated payload. Header + slot AAD are verified here.
        keyBytes = await _crypto.unwrapContentKeyV3(blob: blob, secret: passphrase);
        snapshot = await _crypto.decryptPayloadV3(blob: blob, contentKey: keyBytes);
      } else if (blob.keySlots.isEmpty) {
        snapshot = await _crypto.decryptJson(
          blob: blob,
          passphrase: passphrase.trim(),
        );
      } else {
        try {
          keyBytes = await _crypto.unwrapKeyFromSlots(
            keySlots: blob.keySlots,
            secret: passphrase,
          );
          snapshot = await _crypto.decryptJsonWithRawKey(
            blob: blob,
            keyBytes: keyBytes,
          );
        } on SecretBoxAuthenticationError {
          final legacyKey = await _crypto.deriveKey(
            passphrase: passphrase.trim(),
            salt: blob.salt,
          );
          keyBytes = await legacyKey.extractBytes();
          snapshot = await _crypto.decryptJsonWithRawKey(
            blob: blob,
            keyBytes: keyBytes,
          );
        }
      }
      await RestoreBackupUseCase(_database)(snapshot);
      await _afterRestore?.call();
      await _storage.write(key: _enabledKey, value: '1');
      if (blob.version >= 3) {
        // Preserve the v3 content key + slots so future background backups can
        // re-encrypt without the passphrase, and mark the format as v3.
        await _storage.write(key: _envelopeVersionKey, value: '3');
        await _storage.write(key: _localKeyKey, value: base64Encode(keyBytes!));
        await _storage.write(
          key: _keySlotsKey,
          value: _encodeKeySlots(blob.keySlots),
        );
        await _storage.delete(key: _saltKey);
        await _storage.delete(key: _recoveryKey);
      } else if (keyBytes == null) {
        await _storage.delete(key: _envelopeVersionKey);
        await _storage.write(key: _saltKey, value: base64Encode(blob.salt));
        final key = await _crypto.deriveKey(
          passphrase: passphrase.trim(),
          salt: blob.salt,
        );
        await _storage.write(
          key: _localKeyKey,
          value: base64Encode(await key.extractBytes()),
        );
        await _storage.delete(key: _keySlotsKey);
      } else {
        await _storage.delete(key: _envelopeVersionKey);
        await _storage.write(key: _localKeyKey, value: base64Encode(keyBytes));
        await _storage.write(
          key: _keySlotsKey,
          value: _encodeKeySlots(blob.keySlots),
        );
        await _storage.delete(key: _saltKey);
        await _storage.delete(key: _recoveryKey);
      }
      await _storage.write(
        key: _lastKey,
        value: DateTime.now().toUtc().toIso8601String(),
      );
    } on BackupEnvelopeException catch (e) {
      throw BackupException(_envelopeErrorMessage(e.kind));
    } on SecretBoxAuthenticationError {
      throw const BackupException('كلمة مرور النسخة الاحتياطية غير صحيحة.');
    } on FormatException {
      throw const BackupException('ملف النسخة الاحتياطية غير صالح.');
    }
  }

  // Safe, non-leaking user messages for typed envelope failures (MALI-076n §8).
  // A wrong passphrase, tampering, and corruption are cryptographically
  // indistinguishable, so they share one message.
  static String _envelopeErrorMessage(BackupEnvelopeErrorKind kind) {
    switch (kind) {
      case BackupEnvelopeErrorKind.authenticationFailed:
        return 'تعذّر فك النسخة الاحتياطية: كلمة المرور غير صحيحة أو الملف تالف.';
      case BackupEnvelopeErrorKind.unsupportedVersion:
      case BackupEnvelopeErrorKind.incompatibleSchema:
        return 'هذه النسخة الاحتياطية من إصدار غير مدعوم. حدّث التطبيق ثم أعد المحاولة.';
      case BackupEnvelopeErrorKind.payloadTooLarge:
      case BackupEnvelopeErrorKind.unsafeKdfParams:
      case BackupEnvelopeErrorKind.unsupportedAlgorithm:
      case BackupEnvelopeErrorKind.malformed:
      case BackupEnvelopeErrorKind.decodeFailed:
        return 'ملف النسخة الاحتياطية غير صالح.';
    }
  }

  String _userId() {
    final id = _client.auth.currentUser?.id;
    if (id == null || id.isEmpty) {
      throw const BackupException('سجّل الدخول أولاً لتفعيل النسخ الاحتياطي.');
    }
    return id;
  }

  String _generateRecoveryCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rng = Random.secure();
    String block() =>
        List.generate(4, (_) => chars[rng.nextInt(chars.length)]).join();
    return '${block()}-${block()}-${block()}';
  }

  Future<void> _clearLocalBackupState() async {
    await _storage.delete(key: _enabledKey);
    await _storage.delete(key: _saltKey);
    await _storage.delete(key: _recoveryKey);
    await _storage.delete(key: _lastKey);
    await _storage.delete(key: _localKeyKey);
    await _storage.delete(key: _keySlotsKey);
    await _storage.delete(key: _envelopeVersionKey);
  }

  String _encodeKeySlots(List<BackupKeySlot> slots) {
    return jsonEncode(slots.map((slot) => slot.toJson()).toList());
  }

  List<BackupKeySlot> _decodeKeySlots(String raw) {
    return BackupKeySlot.listFromJson(jsonDecode(raw));
  }
}

String backupStorageExceptionMessage(supabase.StorageException error) {
  if (error.statusCode == '404' ||
      error.message.toLowerCase().contains('bucket not found')) {
    return 'إعداد النسخ الاحتياطي غير مكتمل: أنشئ Storage bucket باسم backups في Supabase ثم جرّب تاني.';
  }
  return 'فشل رفع النسخة الاحتياطية: ${error.message}';
}
