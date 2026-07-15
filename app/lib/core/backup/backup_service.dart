import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../backend/supabase_config.dart';
import '../di/app_providers.dart';
import '../../data/db/app_database.dart';
import '../../features/capture/services/transactions_backfill_service.dart';
import '../../features/planning_sync/services/accounts_backfill_service.dart';
import '../../features/planning_sync/services/planning_primary_backfill_service.dart';
import 'encrypted_backup_service.dart';

class BackupStatus {
  const BackupStatus({required this.enabled, this.lastBackupAt});

  final bool enabled;
  final DateTime? lastBackupAt;
}

class BackupException implements Exception {
  const BackupException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// واجهة النسخ الاحتياطي المشفّر (اختياري، مطفأ افتراضياً).
///
/// TODO(Sprint5-backend): استبدل StubBackupService بتنفيذ E2E حقيقي:
/// اشتقاق مفتاح من passphrase عبر Argon2id + تشفير AES-256-GCM محلياً،
/// ورفع blob مشفّر فقط للسيرفر (لا يملك المفتاح). انظر AUTH_AND_ADMIN_SPEC §4.6.
abstract class BackupService {
  Future<BackupStatus> status();

  Future<bool> hasRemoteBackup();

  /// يفعّل النسخ ويُرجع recovery code للعرض مرة واحدة.
  Future<String> enable({required String passphrase});

  Future<void> backupNow();

  Future<void> restoreFromBackup({required String passphrase});

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
  Future<bool> hasRemoteBackup() async => false;

  @override
  Future<String> enable({required String passphrase}) async {
    // stub: تشفير حقيقي لاحقاً. هنا نولّد recovery code ونسجّل التفعيل فقط.
    final code = _generateRecoveryCode();
    await _storage.write(key: _kEnabled, value: '1');
    await _storage.write(key: _kRecovery, value: code);
    await _storage.write(
        key: _kLast, value: DateTime.now().toUtc().toIso8601String());
    return code;
  }

  @override
  Future<void> backupNow() async {
    await _storage.write(
        key: _kLast, value: DateTime.now().toUtc().toIso8601String());
  }

  @override
  Future<void> restoreFromBackup({required String passphrase}) async {}

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

final backupServiceProvider = Provider<BackupService>((ref) {
  if (SupabaseConfig.isConfigured) {
    final database = ref.watch(appDatabaseProvider);
    return EncryptedBackupService(
      database: database,
      afterRestore: () => _backfillRestoredPrimaryData(database),
    );
  }
  return StubBackupService();
});

Future<void> _backfillRestoredPrimaryData(AppDatabase database) async {
  final flags = featureFlags;
  final accountsPrimary = flags.getBool('accounts_supabase_primary');
  final transactionsPrimary = flags.getBool('transactions_supabase_primary');
  final planningEntities = <String>{
    if (flags.getBool('budgets_supabase_primary')) 'budgets',
    if (flags.getBool('goals_supabase_primary')) 'goals',
    if (flags.getBool('subscriptions_supabase_primary')) 'subscriptions',
    if (flags.getBool('plans_supabase_primary')) 'plans',
  };
  final needsAccounts =
      transactionsPrimary || planningEntities.isNotEmpty || accountsPrimary;
  if (!needsAccounts) return;
  if (!accountsPrimary) {
    throw const BackupException(
      'تعذّرت مزامنة النسخة المستعادة: فعّل مزامنة الحسابات أولاً.',
    );
  }

  final accounts = await AccountsBackfillService(db: database).run();
  if (!accounts.isClean) {
    throw const BackupException('تعذّر ربط حسابات النسخة المستعادة.');
  }
  if (transactionsPrimary) {
    final transactions = await TransactionsBackfillService(db: database).run();
    if (!transactions.isClean) {
      throw const BackupException('تعذّر ربط عمليات النسخة المستعادة.');
    }
  }
  if (planningEntities.isNotEmpty) {
    final planning = await PlanningPrimaryBackfillService(db: database).run(
      onlyEntities: planningEntities,
    );
    if (!planning.isClean) {
      throw const BackupException('تعذّر ربط بيانات التخطيط المستعادة.');
    }
  }
}

final backupStatusProvider = FutureProvider<BackupStatus>((ref) {
  return ref.watch(backupServiceProvider).status();
});
