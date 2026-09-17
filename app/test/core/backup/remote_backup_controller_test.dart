import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backup/backup_service.dart';
import 'package:money_companion/core/backup/restore_controller.dart';
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
  Future<RestorePlan> prepareRestore({required String passphrase}) async =>
      throw UnimplementedError();

  @override
  Future<RestoreResult> commitRestore({required RestoreConfirmation confirmation}) async =>
      throw UnimplementedError();

  @override
  Future<bool> verifyRestoredDatabaseUsable() async => true;

  @override
  Future<void> acknowledgeRestore({required String operationId}) async {}
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
    final c = RemoteBackupController(svc, consentGranted: () async => true);
    expect(c.state, RemoteBackupState.disabled);
    await c.enable(passphrase: 'pw');
    expect(c.state, RemoteBackupState.enabledIdle);
    expect(c.state.isProtected, isTrue);
  });

  test('a failed first upload never shows Protected', () async {
    final svc = _FakeBackupService()
      ..enableError = const RemoteBackupException(RemoteBackupErrorKind.uploadFailed);
    final c = RemoteBackupController(svc, consentGranted: () async => true);
    await c.enable(passphrase: 'pw');
    expect(c.state.isProtected, isFalse);
    expect(c.state, RemoteBackupState.failedRetryable);
  });

  test('consent OFF blocks the backup and shows consentRequired', () async {
    final svc = _FakeBackupService();
    final c = RemoteBackupController(svc, consentGranted: () async => false);
    await c.enable(passphrase: 'pw');
    expect(c.state, RemoteBackupState.consentRequired);
    expect(svc.enableCalls, 0); // no upload attempted
  });

  test('the coordinator serialises operations (no duplicate generations)', () async {
    final svc = _FakeBackupService()
      ..enabled = true
      ..backupGate = Completer<void>();
    final c = RemoteBackupController(svc, consentGranted: () async => true);
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
    final c = RemoteBackupController(svc, consentGranted: () async => true);
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
    final c = RemoteBackupController(svc, consentGranted: () async => true);
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
    final c = RemoteBackupController(svc, consentGranted: () async => true);
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

  test('every state maps to a non-empty label; only enabledIdle is Protected',
      () {
    // The label switch moved to `backup_screen`, where a BuildContext exists,
    // so the words can follow the locale. The CONTRACT is unchanged and is
    // asserted where the copy now lives — in both languages, because "only a
    // committed AND verified generation may read as Protected" is a claim
    // about truthfulness, not about Arabic.
    final ar = jsonDecode(File('lib/l10n/app_ar.arb').readAsStringSync())
        as Map<String, dynamic>;
    final en = jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync())
        as Map<String, dynamic>;
    const keyFor = {
      RemoteBackupState.disabled: 'bkStateDisabled',
      RemoteBackupState.enabling: 'bkStateEnabling',
      RemoteBackupState.preparing: 'bkStatePreparing',
      RemoteBackupState.encrypting: 'bkStateEncrypting',
      RemoteBackupState.uploading: 'bkStateUploading',
      RemoteBackupState.verifyingUpload: 'bkStateVerifying',
      RemoteBackupState.verifyingDownload: 'bkStateVerifying',
      RemoteBackupState.downloading: 'bkStateDownloading',
      RemoteBackupState.enabledIdle: 'bkStateProtected',
      RemoteBackupState.pausedOffline: 'bkStateWaitingForConnection',
      RemoteBackupState.retryScheduled: 'bkStateWillRetry',
      RemoteBackupState.authenticationRequired: 'bkStateNeedsSignIn',
      RemoteBackupState.consentRequired: 'bkStateNeedsCloudSync',
      RemoteBackupState.failedRetryable: 'bkStateFailedRetryable',
      RemoteBackupState.failedTerminal: 'bkStateFailed',
      RemoteBackupState.deleting: 'bkStateDeleting',
      RemoteBackupState.cancelled: 'bkStateCancelled',
    };
    // A new state with no entry here fails, rather than quietly rendering
    // nothing on a screen that is supposed to be truthful about protection.
    expect(keyFor.keys.toSet(), RemoteBackupState.values.toSet());
    for (final entry in keyFor.entries) {
      for (final arb in [ar, en]) {
        expect(arb[entry.value], isA<String>(),
            reason: '${entry.key} has no label');
        expect((arb[entry.value] as String).trim(), isNotEmpty,
            reason: '${entry.key} has an empty label');
      }
    }
    expect(ar['bkStateProtected'], 'محمي');
    expect(en['bkStateProtected'], 'Protected');
    for (final entry in keyFor.entries) {
      if (entry.key == RemoteBackupState.enabledIdle) continue;
      expect(ar[entry.value], isNot('محمي'),
          reason: '${entry.key} must not read as protected');
      expect(en[entry.value], isNot('Protected'),
          reason: '${entry.key} must not read as protected');
    }
  });

  test('C-3: the consent hook defaults to DENY when the caller omits it',
      () async {
    // It defaulted to `() => true` while remoteBackupControllerProvider passed
    // nothing, so the consentRequired branch below was unreachable and the
    // encrypted backup uploaded with cloud consent OFF. A forgotten argument
    // must fail in the direction that cannot leak.
    final svc = _FakeBackupService();
    final c = RemoteBackupController(svc);
    await c.enable(passphrase: 'pw');
    expect(c.state, RemoteBackupState.consentRequired);
    expect(svc.enableCalls, 0, reason: 'no upload may be attempted');
  });

  test('C-3: a revocation between operations is observed', () async {
    var consent = true;
    final svc = _FakeBackupService();
    final c = RemoteBackupController(svc, consentGranted: () async => consent);
    await c.enable(passphrase: 'pw');
    expect(c.state, RemoteBackupState.enabledIdle);

    consent = false;
    await c.backupNow();
    expect(c.state, RemoteBackupState.consentRequired);
    expect(svc.backupCalls, 0, reason: 'consent is read per operation');
  });
}
