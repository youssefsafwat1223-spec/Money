import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class BackupStatus {
  const BackupStatus({required this.enabled, this.lastBackupAt});

  final bool enabled;
  final DateTime? lastBackupAt;
}

/// واجهة النسخ الاحتياطي المشفّر (اختياري، مطفأ افتراضياً).
///
/// TODO(Sprint5-backend): استبدل StubBackupService بتنفيذ E2E حقيقي:
/// اشتقاق مفتاح من passphrase عبر Argon2id + تشفير AES-256-GCM محلياً،
/// ورفع blob مشفّر فقط للسيرفر (لا يملك المفتاح). انظر AUTH_AND_ADMIN_SPEC §4.6.
abstract class BackupService {
  Future<BackupStatus> status();

  /// يفعّل النسخ ويُرجع recovery code للعرض مرة واحدة.
  Future<String> enable({required String passphrase});

  Future<void> backupNow();

  Future<void> disable();
}

class StubBackupService implements BackupService {
  static const FlutterSecureStorage _storage = FlutterSecureStorage();
  static const String _kEnabled = 'backup_enabled';
  static const String _kRecovery = 'backup_recovery_code';
  static const String _kLast = 'backup_last_at';

  @override
  Future<BackupStatus> status() async {
    final enabled = await _storage.read(key: _kEnabled) == '1';
    final lastRaw = await _storage.read(key: _kLast);
    return BackupStatus(
      enabled: enabled,
      lastBackupAt: lastRaw == null ? null : DateTime.tryParse(lastRaw),
    );
  }

  @override
  Future<String> enable({required String passphrase}) async {
    // stub: تشفير حقيقي لاحقاً. هنا نولّد recovery code ونسجّل التفعيل فقط.
    final code = _generateRecoveryCode();
    await _storage.write(key: _kEnabled, value: '1');
    await _storage.write(key: _kRecovery, value: code);
    await _storage.write(key: _kLast, value: DateTime.now().toUtc().toIso8601String());
    return code;
  }

  @override
  Future<void> backupNow() async {
    await _storage.write(key: _kLast, value: DateTime.now().toUtc().toIso8601String());
  }

  @override
  Future<void> disable() async {
    await _storage.delete(key: _kEnabled);
    await _storage.delete(key: _kRecovery);
    await _storage.delete(key: _kLast);
  }

  String _generateRecoveryCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rng = Random.secure();
    String block() =>
        List.generate(4, (_) => chars[rng.nextInt(chars.length)]).join();
    return '${block()}-${block()}-${block()}';
  }
}

final backupServiceProvider = Provider<BackupService>((ref) => StubBackupService());

final backupStatusProvider = FutureProvider<BackupStatus>((ref) {
  return ref.watch(backupServiceProvider).status();
});
