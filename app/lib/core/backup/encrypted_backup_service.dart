import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:cryptography/cryptography.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import '../../data/db/app_database.dart';
import 'backup_crypto.dart';
import 'backup_service.dart';
import 'backup_snapshot_builder.dart';
import 'restore_backup_usecase.dart';

class EncryptedBackupService implements BackupService {
  EncryptedBackupService({
    required AppDatabase database,
    supabase.SupabaseClient? client,
    FlutterSecureStorage? storage,
    BackupCrypto? crypto,
  })  : _database = database,
        _client = client ?? supabase.Supabase.instance.client,
        _storage = storage ?? const FlutterSecureStorage(),
        _crypto = crypto ?? BackupCrypto();

  static const _bucket = 'backups';
  static const _enabledKey = 'backup_enabled';
  static const _saltKey = 'backup_salt';
  static const _recoveryKey = 'backup_recovery_code';
  static const _lastKey = 'backup_last_at';
  static const _localKeyKey = 'backup_local_key';

  final AppDatabase _database;
  final supabase.SupabaseClient _client;
  final FlutterSecureStorage _storage;
  final BackupCrypto _crypto;

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
    final salt = _crypto.randomBytes(16);
    final recovery = _generateRecoveryCode();
    final key = await _crypto.deriveKey(passphrase: passphrase, salt: salt);
    await _storage.write(key: _enabledKey, value: '1');
    await _storage.write(key: _saltKey, value: base64Encode(salt));
    await _storage.write(key: _recoveryKey, value: recovery);
    await _storage.write(
      key: _localKeyKey,
      value: base64Encode(await key.extractBytes()),
    );
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

  @override
  Future<void> backupNow() async {
    final userId = _userId();
    final enabled = await _storage.read(key: _enabledKey) == '1';
    if (!enabled) return;

    final saltRaw = await _storage.read(key: _saltKey);
    final keyRaw = await _storage.read(key: _localKeyKey);
    if (saltRaw == null || keyRaw == null) {
      throw const BackupException('النسخ الاحتياطي يحتاج تفعيل جديد.');
    }

    final snapshot = await BackupSnapshotBuilder(_database).build();
    final blob = await _crypto.encryptJsonWithKey(
      json: snapshot,
      key: SecretKey(base64Decode(keyRaw)),
      salt: base64Decode(saltRaw),
    );
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
      await _client.from('backups').upsert({
        'user_id': userId,
        'blob_path': path,
        'blob_version': 1,
        'size_bytes': bytes.length,
        'updated_at': now.toIso8601String(),
      });
      await _storage.write(key: _lastKey, value: now.toIso8601String());
    } on supabase.StorageException catch (error) {
      throw BackupException(backupStorageExceptionMessage(error));
    }
  }

  @override
  Future<void> disable() async {
    final userId = _client.auth.currentUser?.id;
    if (userId != null) {
      final path = '$userId/backup.enc';
      await _client.storage.from(_bucket).remove([path]);
      await _client.from('backups').delete().eq('user_id', userId);
    }
    await _storage.delete(key: _enabledKey);
    await _storage.delete(key: _saltKey);
    await _storage.delete(key: _recoveryKey);
    await _storage.delete(key: _lastKey);
    await _storage.delete(key: _localKeyKey);
  }

  @override
  Future<void> restoreFromBackup({required String passphrase}) {
    return restore(passphrase: passphrase);
  }

  Future<void> restore({required String passphrase}) async {
    final userId = _userId();
    final path = '$userId/backup.enc';
    final bytes = await _client.storage.from(_bucket).download(path);
    try {
      final blob = EncryptedBackupBlob.fromBytes(bytes);
      final snapshot = await _crypto.decryptJson(
        blob: blob,
        passphrase: passphrase,
      );
      await RestoreBackupUseCase(_database)(snapshot);
      await _storage.write(key: _enabledKey, value: '1');
      await _storage.write(key: _saltKey, value: base64Encode(blob.salt));
      final key = await _crypto.deriveKey(
        passphrase: passphrase,
        salt: blob.salt,
      );
      await _storage.write(
        key: _localKeyKey,
        value: base64Encode(await key.extractBytes()),
      );
      await _storage.write(
        key: _lastKey,
        value: DateTime.now().toUtc().toIso8601String(),
      );
    } on SecretBoxAuthenticationError {
      throw const BackupException('كلمة مرور النسخة الاحتياطية غير صحيحة.');
    } on FormatException {
      throw const BackupException('ملف النسخة الاحتياطية غير صالح.');
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
  }
}

String backupStorageExceptionMessage(supabase.StorageException error) {
  if (error.statusCode == '404' ||
      error.message.toLowerCase().contains('bucket not found')) {
    return 'إعداد النسخ الاحتياطي غير مكتمل: أنشئ Storage bucket باسم backups في Supabase ثم جرّب تاني.';
  }
  return 'فشل رفع النسخة الاحتياطية: ${error.message}';
}
