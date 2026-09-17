import 'package:flutter/widgets.dart';

import '../../core/backup/backup_service.dart';
import '../../core/backup/restore_controller.dart';
import '../../core/utils/l10n_ext.dart';

/// Renders a backup/restore failure in the reader's language.
///
/// The services that raise these have no BuildContext — a Drift transaction, a
/// ValueNotifier, a background upload — so they name the failure with a
/// [BackupError] and carry an Arabic [BackupException.message] for logs. The
/// words are chosen here.
String backupErrorMessage(
  BuildContext context,
  BackupError code, {
  List<String> args = const [],
}) {
  final l = context.l10n;
  return switch (code) {
    BackupError.noLocalBackup => l.bkeNoLocalBackup,
    BackupError.needsReenable => l.bkeNeedsReenable,
    BackupError.signInRequired => l.bkeSignInRequired,
    BackupError.stateSaveFailed => l.bkeStateSaveFailed,
    BackupError.bucketMissing => l.bkeBucketMissing,
    BackupError.uploadFailed => l.bkeUploadFailed(args.isEmpty ? '' : args.first),
    BackupError.wrongPassphrase => l.bkeWrongPassphrase,
    BackupError.invalidBackupFile => l.bkeInvalidBackupFile,
    BackupError.decryptFailed => l.bkeDecryptFailed,
    BackupError.unsupportedEnvelopeVersion => l.bkeUnsupportedEnvelopeVersion,
    BackupError.backupFromNewerApp => l.bkeBackupFromNewerApp,
    BackupError.unsupportedBackupVersion => l.bkeUnsupportedBackupVersion(args.isEmpty ? '' : args.first),
    BackupError.backupCorrupt => l.bkeBackupCorrupt,
    BackupError.tableCorrupt => l.bkeTableCorrupt(args.isEmpty ? '' : args.first),
    BackupError.requiredTableMissing => l.bkeRequiredTableMissing(args.isEmpty ? '' : args.first),
    BackupError.unsupportedTable => l.bkeUnsupportedTable(args.isEmpty ? '' : args.first),
    BackupError.unexpectedSensitiveField => l.bkeUnexpectedSensitiveField(args.isEmpty ? '' : args.first),
    BackupError.invalidMoneyValue => l.bkeInvalidMoneyValue(args.isEmpty ? '' : args.first),
    BackupError.accountChangedDuringRestore => l.bkeAccountChanged,
    BackupError.relationalIntegrityViolated => l.bkeRelationalIntegrity,
    BackupError.planningInconsistent => l.bkePlanningInconsistent,
    BackupError.foreignKeysNotReenabled => l.bkeForeignKeys,
    BackupError.orphanGoalContribution => l.bkeOrphanGoalContribution(args.isEmpty ? '' : args.first),
    BackupError.prepareFailed => l.bkePrepareFailed,
    BackupError.restoreFailedNoChanges => l.bkeRestoreFailedNoChanges,
    BackupError.committedPendingBackupState => l.bkeCommittedPendingBackupState,
    BackupError.restoredButDatabaseNotReady => l.bkeRestoredDbNotReady,
    BackupError.restoreNeedsDatabaseRepair => l.bkeNeedsDatabaseRepair,
  };
}

/// The same, for a thrown exception. A throw site that has not been given a
/// code yet still shows its Arabic message — visible beats blank.
String backupExceptionMessage(BuildContext context, BackupException e) {
  final code = e.code;
  if (code == null) return e.message;
  return backupErrorMessage(context, code, args: e.args);
}

/// The failure carried by a [RestoreUiState], or null when it carries none.
String? restoreStateMessage(BuildContext context, RestoreUiState state) {
  final code = state.code;
  if (code == null) return state.message;
  return backupErrorMessage(context, code, args: state.args);
}
