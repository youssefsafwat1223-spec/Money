// MALI-014 / MALI-076n (Phase 6 Batch 5) — the typed restore result taxonomy.
//
// Every restore attempt resolves to exactly one [RestoreOutcome]. Internal
// exceptions (Drift/SQLite/SQLCipher/Supabase/file/crypto) are mapped to these
// coarse, privacy-safe outcomes and NEVER surfaced raw: no passphrase, key, SQL,
// path, token, raw snapshot field, or financial value ever appears in a result.

enum RestoreOutcome {
  /// The restore committed AND the database reopened successfully.
  success,

  /// The user cancelled before destructive mutation began.
  cancelled,

  /// Wrong passphrase, tampering, or ciphertext corruption (indistinguishable).
  authenticationFailed,

  /// The envelope/snapshot could not be parsed/decoded.
  malformedBackup,

  /// A future/unknown envelope version this build cannot read.
  unsupportedEnvelope,

  /// A snapshot schema newer than this build supports.
  incompatibleSnapshot,

  /// Declared source/ciphertext exceeded the safe byte/resource limits.
  payloadTooLarge,

  /// Admission changed (sign-out / wipe / ownership change / same-UID re-login)
  /// before the destructive mutation committed — aborted without mutation.
  ownershipChanged,

  /// The file-exclusive maintenance gate could not be acquired within the bound.
  maintenanceTimeout,

  /// A transient SQLITE_BUSY/LOCKED after the bounded wait.
  databaseBusy,

  /// Structural / integrity / preflight validation failed before mutation.
  validationFailed,

  /// A failure occurred DURING mutation but the transaction rolled back — the
  /// pre-restore database is intact.
  rollbackCompleted,

  /// The rollback itself could not be confirmed — must transition to
  /// [recoveryRequired] (rare).
  rollbackFailed,

  /// The database could not be reopened after the maintenance window.
  reopenFailed,

  /// The lifecycle is in the terminal recovery-required state.
  recoveryRequired,

  /// The selected local backup file was missing/unreadable.
  localFileUnavailable,

  /// The requested committed remote generation was missing/pruned.
  remoteObjectUnavailable,

  /// The downloaded remote object failed size/hash verification.
  remoteIntegrityFailed,

  /// An unexpected internal failure (mapped, never raw).
  internalFailure,
}

/// The result of a restore attempt. Carries only the outcome, the operation id,
/// and optional privacy-safe warnings — never any secret or financial content.
class RestoreResult {
  const RestoreResult(this.outcome, {this.operationId, this.warnings = const []});

  final RestoreOutcome outcome;

  /// The stable restore-operation id this attempt belonged to (opaque).
  final String? operationId;

  /// Privacy-safe, user-presentable notes (e.g. "restored a v2 backup"). Never
  /// contains raw snapshot fields or financial values.
  final List<String> warnings;

  bool get isSuccess => outcome == RestoreOutcome.success;

  /// True when the pre-restore database is guaranteed intact (no mutation, or a
  /// confirmed rollback).
  bool get databaseUnchanged =>
      outcome == RestoreOutcome.cancelled ||
      outcome == RestoreOutcome.authenticationFailed ||
      outcome == RestoreOutcome.malformedBackup ||
      outcome == RestoreOutcome.unsupportedEnvelope ||
      outcome == RestoreOutcome.incompatibleSnapshot ||
      outcome == RestoreOutcome.payloadTooLarge ||
      outcome == RestoreOutcome.ownershipChanged ||
      outcome == RestoreOutcome.maintenanceTimeout ||
      outcome == RestoreOutcome.databaseBusy ||
      outcome == RestoreOutcome.validationFailed ||
      outcome == RestoreOutcome.rollbackCompleted ||
      outcome == RestoreOutcome.localFileUnavailable ||
      outcome == RestoreOutcome.remoteObjectUnavailable ||
      outcome == RestoreOutcome.remoteIntegrityFailed;

  /// True when the caller must route to the database-recovery flow.
  bool get needsRecovery =>
      outcome == RestoreOutcome.recoveryRequired ||
      outcome == RestoreOutcome.rollbackFailed ||
      outcome == RestoreOutcome.reopenFailed;

  @override
  String toString() => 'RestoreResult(${outcome.name})';
}

/// Thrown INSIDE the restore transaction when in-transaction verification fails,
/// so the whole restore rolls back before commit. Privacy-safe: [reason] is a
/// short protocol label, never data.
class RestoreVerificationException implements Exception {
  const RestoreVerificationException(this.reason);

  /// e.g. 'row_count_mismatch' | 'fk_violation' | 'total_mismatch' |
  /// 'remote_row_present' | 'key_ref_present' | 'cross_user_owner' |
  /// 'duplicate_identifier' | 'missing_singleton'. No data.
  final String reason;

  @override
  String toString() => 'RestoreVerificationException($reason)';
}
