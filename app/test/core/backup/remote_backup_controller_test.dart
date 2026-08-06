import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backup/backup_service.dart';
import 'package:money_companion/core/backup/restore_plan.dart';
import 'package:money_companion/core/backup/restore_result.dart';
import 'package:money_companion/core/backup/remote_backup_controller.dart';
import 'package:money_companion/core/backup/remote_backup_state.dart';

// MALI-076n §16 — truthful state + operation coordinator.
class _FakeBackupService implements BackupService {
  bool enabled = false;
  bool hasRemote = false;
  Object? enableError;
  Object? backupError;
  Completer<void>? backupGate;
  int enableCalls = 0;
  int backupCalls = 0;
  int deleteCalls = 0;

  @override
  Future<BackupStatus> status() async =>
      BackupStatus(enabled: enabled, lastBackupAt: null);
  @override
  Future<bool> hasRemoteBackup() async => hasRemote;
  @override
  Future<String> enable({required String passphrase}) async {
    enableCalls++;
    if (enableError != null) throw enableError!;
    enabled = true;
    hasRemote = true;
    return 'RECOVERY-CODE';
  }

  @override
  Future<void> backupNow() async {
    backupCalls++;
    if (backupGate != null) await backupGate!.future;
    if (backupError != null) throw backupError!;
    hasRemote = true;
  }

  @override
  Future<void> restoreFromBackup({required String passphrase}) async {}

  @override
  Future<RestorePlan> prepareRestore({required String passphrase}) async =>
      throw UnimplementedError();

  @override
  Future<RestoreResult> commitRestore({required RestorePlan plan}) async =>
      throw UnimplementedError();
  @override
  Future<void> disable() async => enabled = false;
  @override
  Future<void> deleteRemoteBackups() async {
    deleteCalls++;
    hasRemote = false;
  }
}

void main() {
  test('Protected only appears after a successful committed backup', () async {
    final svc = _FakeBackupService();
    final c = RemoteBackupController(svc);
    expect(c.state, RemoteBackupState.disabled);
    await c.enable(passphrase: 'pw');
    expect(c.state, RemoteBackupState.enabledIdle);
    expect(c.state.isProtected, isTrue);
  });

  test('a failed first upload never shows Protected', () async {
    final svc = _FakeBackupService()
      ..enableError = const RemoteBackupException(RemoteBackupErrorKind.uploadFailed);
    final c = RemoteBackupController(svc);
    await c.enable(passphrase: 'pw');
    expect(c.state.isProtected, isFalse);
    expect(c.state, RemoteBackupState.failedRetryable);
  });

  test('consent OFF blocks the backup and shows consentRequired', () async {
    final svc = _FakeBackupService();
    final c = RemoteBackupController(svc, consentGranted: () => false);
    await c.enable(passphrase: 'pw');
    expect(c.state, RemoteBackupState.consentRequired);
    expect(svc.enableCalls, 0); // no upload attempted
  });

  test('the coordinator serialises operations (no duplicate generations)', () async {
    final svc = _FakeBackupService()
      ..enabled = true
      ..backupGate = Completer<void>();
    final c = RemoteBackupController(svc);
    final first = c.backupNow(); // starts, blocks on the gate
    expect(c.isBusy, isTrue);
    await c.backupNow(); // refused while busy
    expect(svc.backupCalls, 1); // second call did NOT run
    svc.backupGate!.complete();
    await first;
    expect(c.state, RemoteBackupState.enabledIdle);
  });

  test('error kinds map to the intended states', () async {
    final svc = _FakeBackupService()..enabled = true;
    final c = RemoteBackupController(svc);
    svc.backupError = const RemoteBackupException(RemoteBackupErrorKind.offline);
    await c.backupNow();
    expect(c.state, RemoteBackupState.pausedOffline);
    svc.backupError = const RemoteBackupException(RemoteBackupErrorKind.ownershipMismatch);
    await c.backupNow();
    expect(c.state, RemoteBackupState.failedTerminal);
    svc.backupError = const RemoteBackupException(RemoteBackupErrorKind.authenticationRequired);
    await c.backupNow();
    expect(c.state, RemoteBackupState.authenticationRequired);
  });

  test('refresh reconstructs truthful state from remote truth', () async {
    final svc = _FakeBackupService();
    final c = RemoteBackupController(svc);
    await c.refresh();
    expect(c.state, RemoteBackupState.disabled);
    svc.enabled = true; // enabled locally but no committed remote object
    await c.refresh();
    expect(c.state, RemoteBackupState.failedRetryable);
    svc.hasRemote = true;
    await c.refresh();
    expect(c.state, RemoteBackupState.enabledIdle);
  });

  test('sign-out drops the previous state; disable is stop-only; delete is separate',
      () async {
    final svc = _FakeBackupService()..enabled = true..hasRemote = true;
    final c = RemoteBackupController(svc);
    await c.refresh();
    expect(c.state, RemoteBackupState.enabledIdle);
    c.onSignedOut();
    expect(c.state, RemoteBackupState.disabled);
    // disable stop-only: does not delete remote.
    svc.enabled = true;
    await c.disableStop();
    expect(c.state, RemoteBackupState.disabled);
    expect(svc.deleteCalls, 0);
    // explicit delete is a separate action.
    await c.deleteRemote();
    expect(svc.deleteCalls, 1);
  });

  test('every state maps to a non-empty label; only enabledIdle is Protected', () {
    for (final s in RemoteBackupState.values) {
      expect(remoteBackupStateLabel(s), isNotEmpty);
    }
    expect(remoteBackupStateLabel(RemoteBackupState.enabledIdle), 'محمي');
    expect(remoteBackupStateLabel(RemoteBackupState.uploading), isNot('محمي'));
  });
}
