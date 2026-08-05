import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backup/remote_backup_state.dart';

// MALI-076n (Phase-6 Batch 3) — the pure remote-backup domain: state machine,
// error taxonomy, and bounded retry policy.
void main() {
  group('RemoteBackupState', () {
    test('only enabledIdle is "Protected"', () {
      for (final s in RemoteBackupState.values) {
        expect(s.isProtected, s == RemoteBackupState.enabledIdle,
            reason: '$s.isProtected');
      }
    });

    test('in-flight states are distinct from protected/failed', () {
      expect(RemoteBackupState.uploading.isInFlight, isTrue);
      expect(RemoteBackupState.verifyingUpload.isInFlight, isTrue);
      expect(RemoteBackupState.enabledIdle.isInFlight, isFalse);
      expect(RemoteBackupState.failedTerminal.isInFlight, isFalse);
    });

    test('retryable vs terminal states are distinguishable', () {
      expect(RemoteBackupState.failedRetryable.isRetryable, isTrue);
      expect(RemoteBackupState.pausedOffline.isRetryable, isTrue);
      expect(RemoteBackupState.failedTerminal.isRetryable, isFalse);
      expect(RemoteBackupState.failedTerminal.isTerminalFailure, isTrue);
    });
  });

  group('error classification', () {
    test('transport/transient errors are retryable', () {
      for (final k in [
        RemoteBackupErrorKind.offline,
        RemoteBackupErrorKind.requestTimeout,
        RemoteBackupErrorKind.uploadFailed,
        RemoteBackupErrorKind.downloadFailed,
        RemoteBackupErrorKind.storageUnavailable,
        RemoteBackupErrorKind.uploadVerificationFailed,
      ]) {
        expect(isRetryableRemoteError(k), isTrue, reason: k.name);
      }
    });

    test('authorization/integrity/conflict errors are terminal', () {
      for (final k in [
        RemoteBackupErrorKind.authenticationRequired,
        RemoteBackupErrorKind.ownershipMismatch,
        RemoteBackupErrorKind.staleGeneration,
        RemoteBackupErrorKind.operationConflict,
        RemoteBackupErrorKind.downloadIntegrityFailed,
        RemoteBackupErrorKind.envelopeFailure,
        RemoteBackupErrorKind.restorePreflightFailed,
        RemoteBackupErrorKind.cancelled,
      ]) {
        expect(isRetryableRemoteError(k), isFalse, reason: k.name);
      }
    });
  });

  group('RemoteBackupRetryPolicy', () {
    const policy = RemoteBackupRetryPolicy(
        baseDelayMs: 1000, factor: 2, maxDelayMs: 60000, maxAttempts: 5);

    test('offline pauses WITHOUT consuming an attempt', () {
      final d = policy.decide(
          kind: RemoteBackupErrorKind.requestTimeout, attempt: 0, online: false);
      expect(d.outcome, RemoteRetryOutcome.paused);
      final d2 = policy.decide(
          kind: RemoteBackupErrorKind.offline, attempt: 3, online: true);
      expect(d2.outcome, RemoteRetryOutcome.paused);
    });

    test('a terminal error never retries', () {
      final d = policy.decide(
          kind: RemoteBackupErrorKind.ownershipMismatch,
          attempt: 0,
          online: true);
      expect(d.outcome, RemoteRetryOutcome.terminal);
    });

    test('retryable error backs off exponentially, bounded, with jitter', () {
      // jitter01=1.0 → full delay; jitter01=0.0 → half delay (full-jitter band).
      final a0 = policy.decide(
          kind: RemoteBackupErrorKind.uploadFailed,
          attempt: 0,
          online: true,
          jitter01: 1.0);
      final a1 = policy.decide(
          kind: RemoteBackupErrorKind.uploadFailed,
          attempt: 1,
          online: true,
          jitter01: 1.0);
      final a2 = policy.decide(
          kind: RemoteBackupErrorKind.uploadFailed,
          attempt: 2,
          online: true,
          jitter01: 1.0);
      expect(a0.delayMs, 1000);
      expect(a1.delayMs, 2000);
      expect(a2.delayMs, 4000);
      // Jitter halves the floor.
      final floor = policy.decide(
          kind: RemoteBackupErrorKind.uploadFailed,
          attempt: 2,
          online: true,
          jitter01: 0.0);
      expect(floor.delayMs, 2000);
    });

    test('delay is capped at maxDelayMs', () {
      final d = policy.decide(
          kind: RemoteBackupErrorKind.uploadFailed,
          attempt: 4,
          online: true,
          jitter01: 1.0);
      expect(d.delayMs, lessThanOrEqualTo(60000));
    });

    test('attempts beyond maxAttempts become terminal', () {
      final d = policy.decide(
          kind: RemoteBackupErrorKind.uploadFailed,
          attempt: 5,
          online: true);
      expect(d.outcome, RemoteRetryOutcome.terminal);
    });
  });

  test('a typed error never leaks its cause as a raw string', () {
    const e = RemoteBackupException(RemoteBackupErrorKind.uploadVerificationFailed);
    expect(e.toString(), 'RemoteBackupException(uploadVerificationFailed)');
    expect(e.toString().contains('token'), isFalse);
  });
}
