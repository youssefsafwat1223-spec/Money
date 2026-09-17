import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../backend/supabase_config.dart';
import '../../data/repositories/drift_user_settings_repository.dart';
import '../di/app_providers.dart';
import '../privacy/consent_authority.dart';
import 'encrypted_backup_service.dart';
import 'remote_backup_controller.dart';
import 'remote_backup_state.dart';
import 'restore_controller.dart';
import 'restore_plan.dart';
import 'restore_result.dart';
import '../security/secure_storage_options.dart';

class BackupStatus {
  const BackupStatus({required this.enabled, this.lastBackupAt});

  final bool enabled;
  final DateTime? lastBackupAt;
}

/// The locale-independent identity of a backup or restore failure.
///
/// Same contract as `DataPortabilityError`: the services that throw these run
/// with no BuildContext — background isolates, a ValueNotifier, a Drift
/// transaction — so they cannot resolve an ARB string. They name WHAT went
/// wrong; `backupErrorMessage(context, …)` at the UI chooses the words.
///
/// A value here is a promise to the UI, so removing or renaming one is a
/// breaking change: `backup_error_messages.dart` switches exhaustively and the
/// analyzer fails on a missing arm.
enum BackupError {
  // ---- local state ----
  noLocalBackup,
  needsReenable,
  signInRequired,
  stateSaveFailed,

  // ---- transport ----
  bucketMissing,
  uploadFailed,

  // ---- envelope / passphrase ----
  wrongPassphrase,
  invalidBackupFile,
  decryptFailed,
  unsupportedEnvelopeVersion,

  // ---- version compatibility ----
  backupFromNewerApp,
  unsupportedBackupVersion,

  // ---- payload shape ----
  backupCorrupt,
  tableCorrupt,
  requiredTableMissing,
  unsupportedTable,
  unexpectedSensitiveField,
  invalidMoneyValue,

  // ---- post-restore invariants ----
  accountChangedDuringRestore,
  relationalIntegrityViolated,
  planningInconsistent,
  foreignKeysNotReenabled,
  orphanGoalContribution,

  // ---- restore controller outcomes (no exception, a UI phase) ----
  prepareFailed,
  restoreFailedNoChanges,
  committedPendingBackupState,
  restoredButDatabaseNotReady,
  restoreNeedsDatabaseRepair,
}

class BackupException implements Exception {
  /// [message] stays required and Arabic: it is what a log line, a crash
  /// report, and any throw site not yet given a [code] will show. [code] is
  /// what the UI renders from. Visible-but-Arabic beats silently blank.
  const BackupException(this.message, {this.code, this.args = const []});

  final String message;
  final BackupError? code;

  /// Values interpolated into the message — a table name, a column, a size.
  /// Never localized: they are identifiers, not copy.
  final List<String> args;

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

  /// MALI-014 §Blocker-1/5 — the ONLY restore path is two-phase: [prepareRestore]
  /// downloads/decrypts/validates and returns an immutable plan WITHOUT mutating
  /// anything; the canonical UI flow (RestoreController) then obtains an explicit
  /// user confirmation, which mints the unforgeable [RestoreConfirmation]
  /// capability that [commitRestore] REQUIRES. There is no combined prepare+commit
  /// production entry point, so destructive mutation cannot bypass confirmation.
  Future<RestorePlan> prepareRestore({required String passphrase});

  Future<RestoreResult> commitRestore(
      {required RestoreConfirmation confirmation});

  /// Post-commit usability proof — the restored database must be readable AND still
  /// owned by the admission that ran the restore. The controller shows `completed`
  /// only after this succeeds, and acknowledges only then.
  Future<bool> verifyRestoredDatabaseUsable();

  /// Durable, idempotent acknowledgement of a committed restore — called ONLY after
  /// the database is proven usable (never before).
  Future<void> acknowledgeRestore({required String operationId});

  /// Stop future backups (MALI-076n §3) — does NOT delete remote data.
  Future<void> disable();

  /// The separate, explicit destructive action: delete the remote backup(s).
  Future<void> deleteRemoteBackups();
}

class StubBackupService implements BackupService {
  static const FlutterSecureStorage _storage = SecureStorageOptions.storage;
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
  Future<RestorePlan> prepareRestore({required String passphrase}) async =>
      throw const BackupException('لا توجد نسخة احتياطية على هذا الجهاز.',
          code: BackupError.noLocalBackup);

  @override
  Future<RestoreResult> commitRestore(
          {required RestoreConfirmation confirmation}) async =>
      const RestoreResult(RestoreOutcome.internalFailure);

  @override
  Future<bool> verifyRestoredDatabaseUsable() async => false;

  @override
  Future<void> acknowledgeRestore({required String operationId}) async {}

  @override
  Future<void> disable() async {
    await _storage.delete(key: _kEnabled);
    await _storage.delete(key: _kRecovery);
    await _storage.delete(key: _kLast);
  }

  @override
  Future<void> deleteRemoteBackups() async {}

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
    // MALI-034: Drift is authoritative — a restore repopulates local Drift and
    // the next startupSyncReconcile pushes restored rows to Supabase. The old
    // *_supabase_primary-gated post-restore backfill is retired.
    return EncryptedBackupService(database: database);
  }
  return StubBackupService();
});

/// MALI-076n §16 — the truthful remote-backup state, wired to the screen.
final remoteBackupControllerProvider =
    StateNotifierProvider<RemoteBackupController, RemoteBackupState>((ref) {
  // C-3 — the encrypted backup is user financial data; uploading it needs cloud
  // consent. Consulted fresh at each operation so a revocation is observed.
  final controller = RemoteBackupController(
    ref.watch(backupServiceProvider),
    consentGranted: () => ConsentAuthority(
      () => DriftUserSettingsRepository(ref.read(appDatabaseProvider))
          .getSettings(),
    ).allows(EgressClass.backup),
  );
  // Reconstruct truthful state from remote truth on first read.
  controller.refresh();
  return controller;
});


final backupStatusProvider = FutureProvider<BackupStatus>((ref) {
  return ref.watch(backupServiceProvider).status();
});
