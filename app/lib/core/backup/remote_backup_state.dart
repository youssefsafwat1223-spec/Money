// MALI-076n / MALI-014 (Phase-6 Batch 3) — the typed remote-backup domain: an
// authoritative state machine, a safe error taxonomy, a bounded retry policy, and
// a generation/operation identity model. Pure Dart (no Supabase/IO) so every rule
// is deterministically unit-testable.

/// One authoritative state for the remote-backup subsystem. A boolean like
/// `backupEnabled`/`hasBackup`/`isLoading` cannot represent these distinctly, so
/// the UI could claim remote protection before an upload is committed + verified.
enum RemoteBackupState {
  disabled,
  enabling,
  enabledIdle,
  preparing,
  encrypting,
  uploading,
  verifyingUpload,
  downloading,
  verifyingDownload,
  deleting,
  retryScheduled,
  pausedOffline,
  authenticationRequired,
  consentRequired,
  failedRetryable,
  failedTerminal,
}

extension RemoteBackupStateX on RemoteBackupState {
  /// True only when a verified, committed backup exists and no op is in flight —
  /// the ONLY state the UI may render as "Protected".
  bool get isProtected => this == RemoteBackupState.enabledIdle;

  /// A user-actionable retry is available.
  bool get isRetryable =>
      this == RemoteBackupState.failedRetryable ||
      this == RemoteBackupState.retryScheduled ||
      this == RemoteBackupState.pausedOffline;

  bool get isTerminalFailure => this == RemoteBackupState.failedTerminal;

  bool get isInFlight =>
      this == RemoteBackupState.enabling ||
      this == RemoteBackupState.preparing ||
      this == RemoteBackupState.encrypting ||
      this == RemoteBackupState.uploading ||
      this == RemoteBackupState.verifyingUpload ||
      this == RemoteBackupState.downloading ||
      this == RemoteBackupState.verifyingDownload ||
      this == RemoteBackupState.deleting;
}

/// Safe, typed remote-backup failures. Carries no passphrase, token, auth header,
/// signed URL, object path, blob bytes, plaintext, financial data, or raw
/// provider message.
enum RemoteBackupErrorKind {
  authenticationRequired,
  consentRequired,
  offline,
  requestTimeout,
  uploadFailed,
  downloadFailed,
  uploadVerificationFailed,
  downloadIntegrityFailed,
  remoteObjectMissing,
  remoteMetadataMissing,
  ownershipMismatch,
  staleGeneration,
  operationConflict,
  quotaExceeded,
  storageUnavailable,
  deletionFailed,
  envelopeFailure,
  restorePreflightFailed,
  cancelled,
  internalError,
}

class RemoteBackupException implements Exception {
  const RemoteBackupException(this.kind, {this.causeKind});

  final RemoteBackupErrorKind kind;

  /// An optional safe nested cause (never a raw exception/string).
  final Object? causeKind;

  @override
  String toString() => causeKind == null
      ? 'RemoteBackupException(${kind.name})'
      : 'RemoteBackupException(${kind.name}; cause=$causeKind)';
}

/// Whether a failure of [kind] may be retried. Terminal failures must never loop.
bool isRetryableRemoteError(RemoteBackupErrorKind kind) {
  switch (kind) {
    // Transient / transport — safe to retry.
    case RemoteBackupErrorKind.offline:
    case RemoteBackupErrorKind.requestTimeout:
    case RemoteBackupErrorKind.uploadFailed:
    case RemoteBackupErrorKind.downloadFailed:
    case RemoteBackupErrorKind.storageUnavailable:
    case RemoteBackupErrorKind.uploadVerificationFailed:
      return true;
    // Terminal — retrying cannot help (or is unsafe).
    case RemoteBackupErrorKind.authenticationRequired:
    case RemoteBackupErrorKind.consentRequired:
    case RemoteBackupErrorKind.ownershipMismatch:
    case RemoteBackupErrorKind.staleGeneration:
    case RemoteBackupErrorKind.operationConflict:
    case RemoteBackupErrorKind.quotaExceeded:
    case RemoteBackupErrorKind.remoteObjectMissing:
    case RemoteBackupErrorKind.remoteMetadataMissing:
    case RemoteBackupErrorKind.downloadIntegrityFailed:
    case RemoteBackupErrorKind.deletionFailed:
    case RemoteBackupErrorKind.envelopeFailure:
    case RemoteBackupErrorKind.restorePreflightFailed:
    case RemoteBackupErrorKind.cancelled:
    case RemoteBackupErrorKind.internalError:
      return false;
  }
}

/// A bounded exponential backoff with jitter for retryable remote operations.
/// Offline does NOT consume an attempt (it pauses). Deterministic given an
/// injected [jitter01] in [0,1) so tests are stable.
class RemoteBackupRetryPolicy {
  const RemoteBackupRetryPolicy({
    this.baseDelayMs = 2000,
    this.factor = 2,
    this.maxDelayMs = 5 * 60 * 1000, // 5 min cap
    this.maxAttempts = 6,
  });

  final int baseDelayMs;
  final int factor;
  final int maxDelayMs;
  final int maxAttempts;

  /// Decide the next step after [attempt] failures (attempt is the count of
  /// attempts ALREADY made). [jitter01] in [0,1) provides deterministic jitter.
  RemoteRetryDecision decide({
    required RemoteBackupErrorKind kind,
    required int attempt,
    required bool online,
    double jitter01 = 0.0,
  }) {
    if (kind == RemoteBackupErrorKind.offline || !online) {
      // Pause; do NOT burn an attempt while offline.
      return const RemoteRetryDecision.paused();
    }
    if (!isRetryableRemoteError(kind) || attempt >= maxAttempts) {
      return const RemoteRetryDecision.terminal();
    }
    var delay = baseDelayMs;
    for (var i = 0; i < attempt; i++) {
      delay *= factor;
      if (delay >= maxDelayMs) {
        delay = maxDelayMs;
        break;
      }
    }
    if (delay > maxDelayMs) delay = maxDelayMs;
    // Full jitter in [delay/2, delay].
    final jittered = (delay / 2) + (delay / 2) * jitter01;
    return RemoteRetryDecision.retry(delayMs: jittered.round());
  }
}

enum RemoteRetryOutcome { retry, paused, terminal }

class RemoteRetryDecision {
  const RemoteRetryDecision.retry({required this.delayMs})
      : outcome = RemoteRetryOutcome.retry;
  const RemoteRetryDecision.paused()
      : outcome = RemoteRetryOutcome.paused,
        delayMs = 0;
  const RemoteRetryDecision.terminal()
      : outcome = RemoteRetryOutcome.terminal,
        delayMs = 0;

  final RemoteRetryOutcome outcome;
  final int delayMs;
}

/// Server-committed backup generation + the durable client operation identity
/// that makes uploads idempotent across lost responses. Owner is server-derived;
/// the client never supplies an authoritative owner id.
class RemoteBackupGeneration {
  const RemoteBackupGeneration({
    required this.generationId,
    required this.objectPath,
    required this.envelopeVersion,
    required this.sizeBytes,
    required this.blobSha256,
  });

  final String generationId;
  final String objectPath;
  final int envelopeVersion;
  final int sizeBytes;

  /// Integrity/transport hash of the ENCRYPTED blob. NOT a substitute for the v3
  /// AEAD authentication — it only detects truncation/corruption in transit.
  final String blobSha256;
}
