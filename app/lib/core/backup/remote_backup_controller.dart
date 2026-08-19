import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'backup_service.dart';
import 'remote_backup_state.dart';

// MALI-076n §16 / §14 (Phase-6 Batch-3 closure) — the truthful remote-backup
// controller. It derives a typed [RemoteBackupState] (never a boolean), so the UI
// shows "Protected" ONLY after a remotely committed + verified generation, and it
// serialises every operation through one coordinator so a manual and an automatic
// backup can never independently upload duplicate generations.
class RemoteBackupController extends StateNotifier<RemoteBackupState> {
  RemoteBackupController(this._service, {bool Function()? consentGranted})
      : _consentGranted = consentGranted ?? (() => true),
        super(RemoteBackupState.disabled);

  final BackupService _service;
  final bool Function() _consentGranted;

  // The durable operation coordinator: a single in-flight operation at a time.
  bool _busy = false;
  bool get isBusy => _busy;

  /// Reconstruct the truthful state from remote truth + the local enabled flag
  /// (called on startup/resume and after sign-out). "Protected" requires an
  /// actual committed remote backup, not just the local preference.
  Future<void> refresh() async {
    if (_busy) return;
    final status = await _service.status();
    if (!status.enabled) {
      state = RemoteBackupState.disabled;
      return;
    }
    final hasRemote = await _service.hasRemoteBackup();
    // Enabled locally but no committed remote object yet ⇒ not protected.
    state = hasRemote
        ? RemoteBackupState.enabledIdle
        : RemoteBackupState.failedRetryable;
  }

  /// Sign-out / ownership change: drop the previous user's state. Any queued
  /// operation is refused while this resets (the coordinator gate).
  void onSignedOut() {
    _busy = false;
    state = RemoteBackupState.disabled;
  }

  Future<String?> enable({required String passphrase}) =>
      _run<String>(() async {
        if (!_consentGranted()) {
          state = RemoteBackupState.consentRequired;
          return null;
        }
        state = RemoteBackupState.enabling;
        final recovery = await _service.enable(passphrase: passphrase);
        // Protected ONLY now — enable() completed the verified upload + commit.
        state = RemoteBackupState.enabledIdle;
        return recovery;
      });

  Future<void> backupNow() => _run<void>(() async {
        if (!_consentGranted()) {
          state = RemoteBackupState.consentRequired;
          return;
        }
        state = RemoteBackupState.uploading;
        await _service.backupNow();
        state = RemoteBackupState.enabledIdle;
      });

  /// Stop future backups only (never deletes remote data).
  Future<void> disableStop() => _run<void>(() async {
        await _service.disable();
        state = RemoteBackupState.disabled;
      });

  /// The separate explicit destructive action.
  Future<void> deleteRemote() => _run<void>(() async {
        state = RemoteBackupState.deleting;
        await _service.deleteRemoteBackups();
        state = RemoteBackupState.disabled;
      });

  Future<T?> _run<T>(Future<T?> Function() op) async {
    // one operation at a time — no duplicate generations
    if (_busy) {
      return null;
    }
    _busy = true;
    try {
      return await op();
    } on RemoteBackupException catch (e) {
      state = _stateForError(e.kind);
      return null;
    } catch (_) {
      // Envelope/IO/BackupException etc. — treat as retryable by default.
      state = RemoteBackupState.failedRetryable;
      return null;
    } finally {
      _busy = false;
    }
  }

  RemoteBackupState _stateForError(RemoteBackupErrorKind kind) {
    switch (kind) {
      case RemoteBackupErrorKind.authenticationRequired:
        return RemoteBackupState.authenticationRequired;
      case RemoteBackupErrorKind.consentRequired:
        return RemoteBackupState.consentRequired;
      case RemoteBackupErrorKind.offline:
        return RemoteBackupState.pausedOffline;
      default:
        return isRetryableRemoteError(kind)
            ? RemoteBackupState.failedRetryable
            : RemoteBackupState.failedTerminal;
    }
  }
}

/// Truthful user-facing label for each state (MALI-076n §16). Only `enabledIdle`
/// (a committed + verified generation) renders as "Protected".
String remoteBackupStateLabel(RemoteBackupState s) {
  switch (s) {
    case RemoteBackupState.disabled:
      return 'النسخ الاحتياطي متوقف';
    case RemoteBackupState.enabling:
      return 'جارٍ التفعيل…';
    case RemoteBackupState.preparing:
      return 'جارٍ التحضير…';
    case RemoteBackupState.encrypting:
      return 'جارٍ التشفير…';
    case RemoteBackupState.uploading:
      return 'جارٍ الرفع…';
    case RemoteBackupState.verifyingUpload:
    case RemoteBackupState.verifyingDownload:
      return 'جارٍ التحقق…';
    case RemoteBackupState.downloading:
      return 'جارٍ التنزيل…';
    case RemoteBackupState.enabledIdle:
      return 'محمي';
    case RemoteBackupState.pausedOffline:
      return 'بانتظار الاتصال';
    case RemoteBackupState.retryScheduled:
      return 'ستتم إعادة المحاولة';
    case RemoteBackupState.authenticationRequired:
      return 'يلزم تسجيل الدخول';
    case RemoteBackupState.consentRequired:
      return 'يلزم تفعيل المزامنة السحابية';
    case RemoteBackupState.failedRetryable:
      return 'فشل — أعد المحاولة';
    case RemoteBackupState.failedTerminal:
      return 'فشل';
    case RemoteBackupState.deleting:
      return 'جارٍ حذف النسخة عن بُعد';
    case RemoteBackupState.cancelled:
      return 'أُلغيت';
  }
}
