import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backup/backup_service.dart';
import 'package:money_companion/core/backup/remote_backup_controller.dart';
import 'package:money_companion/core/backup/remote_backup_state.dart';
import 'package:money_companion/core/backup/restore_plan.dart';
import 'package:money_companion/core/backup/restore_controller.dart';
import 'package:money_companion/core/backup/restore_result.dart';

/// Two defects found by `cloud_backup_e2e_test`, which is the first thing that
/// ever ran the cloud path end to end. Both are the kind that a unit test
/// cannot find on its own and that a runtime test finds immediately.
///
/// 1. `hasRemoteBackup()` looked for the fixed legacy object
///    `<owner>/backup.enc`. `backupNow()` stopped writing that path when
///    generation publishing landed: it writes `<owner>/g/<id>.enc` and commits
///    a pointer. So the check returned false for every backup the shipping
///    code produces — and it is what the Data Transfer screen and the
///    post-reinstall restore prompt ask before offering to restore. A user who
///    reinstalled was told they had no backup while `prepareRestore` would
///    have opened it.
///
/// 2. The backup screen called `backupServiceProvider.enable()` directly,
///    bypassing `RemoteBackupController` — which is where the cloud-consent
///    gate lives. An encrypted copy of the entire ledger was uploaded with
///    cloud consent OFF. The controller's own comment records this exact class
///    of bug being closed once before on a different path.
void main() {
  group('backup discovery agrees with the restore path', () {
    final source =
        File('lib/core/backup/encrypted_backup_service.dart').readAsStringSync();

    test('hasRemoteBackup consults the generation pointer, not just the '
        'legacy object', () {
      final body = source.substring(
        source.indexOf('Future<bool> hasRemoteBackup()'),
        source.indexOf('Future<String> enable('),
      );
      expect(body, contains('readCurrentGeneration'),
          reason: 'discovery must ask the same source of truth prepareRestore '
              'uses, or the app hides a backup it could restore');
      // The legacy path stays, as a fallback for installs that predate
      // generation publishing.
      expect(body, contains("'backup.enc'"),
          reason: 'the legacy fallback was removed — pre-generation installs '
              'would stop seeing their backup');
    });

    test('deleteRemoteBackups still clears BOTH representations', () {
      final body = source.substring(source.indexOf('deleteRemoteBackups()'));
      expect(body.contains('readCurrentGeneration'), isTrue);
      expect(body.contains('backup.enc'), isTrue,
          reason: 'a delete that leaves the legacy object behind would make '
              'hasRemoteBackup keep reporting a backup that cannot be opened');
    });
  });

  group('the backup-existence probe is gated too', () {
    test('Data Transfer asks consent before asking the server', () {
      // `_checkLegacyBackup()` runs on `initState` and is EGRESS: it reads the
      // generation pointer and lists the user's storage prefix — two
      // authenticated requests the moment the screen opens. It was gated on
      // `SupabaseConfig.isConfigured` alone, which asks whether the app CAN
      // reach the server, not whether the user agreed that it should.
      final screen = File('lib/features/settings/data_transfer_screen.dart')
          .readAsStringSync();
      final probe = screen.substring(
        screen.indexOf('Future<void> _checkLegacyBackup()'),
        screen.indexOf('Future<void> _pickFile()'),
      );
      expect(probe, contains('EgressClass.backup'),
          reason: 'the probe contacts Supabase with no consent check');
      // And the consent check must come BEFORE the request, not after it.
      expect(probe.indexOf('EgressClass.backup'),
          lessThan(probe.indexOf('hasRemoteBackup()')),
          reason: 'consent is checked after the request has already gone out');
    });
  });

  group('discovery and restore agree on what is restorable', () {
    test('a failed generation download falls through to the legacy object',
        () {
      // `hasRemoteBackup()` reports a backup when EITHER the pointer or the
      // legacy object exists. If restore accepts only the pointer once one
      // exists, an install with both — a pre-generation backup plus a pointer
      // whose object is gone — is offered a restore that can never run.
      final source = File('lib/core/backup/encrypted_backup_service.dart')
          .readAsStringSync();
      final prepare = source.substring(
        source.indexOf('Future<RestorePlan> prepareRestore('),
        source.indexOf('Future<RestoreResult> commitRestore('),
      );
      expect(prepare, contains("download('\$userId/backup.enc')"),
          reason: 'restore has no legacy fallback');
      expect(prepare, contains('bytes ??='),
          reason: 'the legacy path is not reachable after a generation '
              'download failure');
    });
  });

  group('turning backup on cannot bypass cloud consent', () {
    test('the backup screen goes through the controller, not the service', () {
      final screen =
          File('lib/features/backup/backup_screen.dart').readAsStringSync();
      expect(screen, isNot(contains('backupServiceProvider).enable(')),
          reason: 'calling the service directly skips the consent gate and '
              'uploads the ledger with cloud consent OFF');
      expect(screen, contains('remoteBackupControllerProvider.notifier'));
    });

    test('the controller refuses to enable without consent, and uploads '
        'nothing', () async {
      final service = _RecordingBackupService();
      final controller =
          RemoteBackupController(service, consentGranted: () async => false);

      final code = await controller.enable(passphrase: 'irrelevant');

      expect(code, isNull, reason: 'no recovery code without consent');
      expect(service.enableCalls, 0,
          reason: 'the service was reached anyway — nothing about the gate '
              'worked');
      expect(controller.state, RemoteBackupState.consentRequired);
    });

    test('with consent it does enable', () async {
      final service = _RecordingBackupService();
      final controller =
          RemoteBackupController(service, consentGranted: () async => true);

      final code = await controller.enable(passphrase: 'irrelevant');

      expect(code, 'RECOVERY-CODE');
      expect(service.enableCalls, 1);
      expect(controller.state, RemoteBackupState.enabledIdle);
    });

    test('a controller built without a consent function denies', () async {
      // The default must fail CLOSED. A forgotten argument previously meant
      // "allow", which is how the gate came to be dead code the first time.
      final service = _RecordingBackupService();
      final controller = RemoteBackupController(service);

      expect(await controller.enable(passphrase: 'irrelevant'), isNull);
      expect(service.enableCalls, 0);
    });
  });
}

class _RecordingBackupService implements BackupService {
  int enableCalls = 0;

  @override
  Future<String> enable({required String passphrase}) async {
    enableCalls += 1;
    return 'RECOVERY-CODE';
  }

  @override
  Future<BackupStatus> status() async =>
      const BackupStatus(enabled: false, lastBackupAt: null);

  @override
  Future<bool> hasRemoteBackup() async => false;

  @override
  Future<void> backupNow() async {}

  @override
  Future<RestorePlan> prepareRestore({required String passphrase}) =>
      throw UnimplementedError();

  @override
  Future<RestoreResult> commitRestore(
          {required RestoreConfirmation confirmation}) =>
      throw UnimplementedError();

  @override
  Future<bool> verifyRestoredDatabaseUsable() async => true;

  @override
  Future<void> acknowledgeRestore({required String operationId}) async {}

  @override
  Future<void> disable() async {}

  @override
  Future<void> deleteRemoteBackups() async {}
}
