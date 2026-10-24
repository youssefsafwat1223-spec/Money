import 'apple_deletion_reauth.dart';
import 'immediate_account_deletion.dart' show ImmediateChallengeRefusal;
import 'prepared_immediate_deletion_gateway.dart';

/// What the Delete Account screen may honestly say. Only [DeletionFlowCompleted]
/// is a finished deletion: it needs operation-bound remote completion AND a
/// confirmed removal of the original local replica. Everything else is either
/// work still pending, an unknown outcome, or a refusal; none of them touches
/// local data.
sealed class DeletionFlowResult {
  const DeletionFlowResult();
}

final class DeletionFlowCompleted extends DeletionFlowResult {
  const DeletionFlowCompleted();
}

/// The server finished deleting the account but removal of the local replica on
/// this device did not confirm. The remote deletion is NOT in doubt; the local
/// cleanup is.
final class DeletionFlowLocalCleanupPending extends DeletionFlowResult {
  const DeletionFlowLocalCleanupPending();
}

/// Accepted, in progress or already pending server-side. Not deleted yet.
final class DeletionFlowPending extends DeletionFlowResult {
  const DeletionFlowPending();
}

/// The outcome could not be confirmed. [canCheckStatus] says whether a
/// read-only status check on the same operation can still resolve it.
final class DeletionFlowUnconfirmed extends DeletionFlowResult {
  const DeletionFlowUnconfirmed({required this.canCheckStatus});
  final bool canCheckStatus;
}

/// Nothing was deleted. Raised only before a deletion request was sent.
final class DeletionFlowFailed extends DeletionFlowResult {
  const DeletionFlowFailed({required this.retryable});
  final bool retryable;
}

final class DeletionFlowAdminBlocked extends DeletionFlowResult {
  const DeletionFlowAdminBlocked();
}

final class DeletionFlowRateLimited extends DeletionFlowResult {
  const DeletionFlowRateLimited();
}

/// The person dismissed the Apple sheet. No request was sent.
final class DeletionFlowCancelled extends DeletionFlowResult {
  const DeletionFlowCancelled();
}

/// One captured deletion operation.
abstract interface class DeletionFlowSession {
  /// challenge -> Apple re-authentication -> request, then (only on verified
  /// remote completion) original-owner local removal.
  Future<DeletionFlowResult> confirm();

  /// Read-only status check of an operation that already sent (or restored) a
  /// request. Never starts a new deletion.
  Future<DeletionFlowResult> checkStatus();

  /// Releases a session the person abandoned before confirming.
  void close();
}

abstract interface class ImmediateDeletionFlow {
  /// Captures a NEW operation for the current admitted account, or null.
  Future<DeletionFlowSession?> begin();

  /// Captures the current account's EXISTING pending operation, or null.
  Future<DeletionFlowSession?> resume();
}

/// Fail-closed flow for builds/scopes that cannot reach the backend.
class UnavailableDeletionFlow implements ImmediateDeletionFlow {
  const UnavailableDeletionFlow();
  @override
  Future<DeletionFlowSession?> begin() async => null;
  @override
  Future<DeletionFlowSession?> resume() async => null;
}

class GatewayDeletionFlow implements ImmediateDeletionFlow {
  GatewayDeletionFlow(
      {required PreparedImmediateDeletionGateway gateway,
      required AppleDeletionReauth apple})
      : _gateway = gateway,
        _apple = apple;
  final PreparedImmediateDeletionGateway _gateway;
  final AppleDeletionReauth _apple;

  @override
  Future<DeletionFlowSession?> begin() async {
    final op = await _gateway.prepare();
    return op == null ? null : _GatewaySession(_gateway, _apple, op, false);
  }

  @override
  Future<DeletionFlowSession?> resume() async {
    final op = await _gateway.resumePending();
    return op == null ? null : _GatewaySession(_gateway, _apple, op, true);
  }
}

final class _GatewaySession implements DeletionFlowSession {
  _GatewaySession(this._gateway, this._apple, this._op, this._requested);
  final PreparedImmediateDeletionGateway _gateway;
  final AppleDeletionReauth _apple;
  final PreparedDeletionOperation _op;

  /// True once a deletion request was (or may have been) sent, or restored.
  bool _requested;
  bool _busy = false;

  @override
  Future<DeletionFlowResult> confirm() async {
    if (_requested) return checkStatus();
    if (_busy) return const DeletionFlowFailed(retryable: true);
    _busy = true;
    try {
      final challenge = await _gateway.challenge(_op);
      switch (challenge) {
        case PreparedChallengeUnavailable():
          return const DeletionFlowFailed(retryable: false);
        case PreparedChallengeFailed(:final retryable):
          return DeletionFlowFailed(retryable: retryable);
        case PreparedChallengeRefused(:final reason):
          return switch (reason) {
            ImmediateChallengeRefusal.adminBlocked =>
              const DeletionFlowAdminBlocked(),
            ImmediateChallengeRefusal.rateLimited =>
              const DeletionFlowRateLimited(),
            ImmediateChallengeRefusal.alreadyPending =>
              const DeletionFlowPending(),
          };
        case PreparedChallengeIssued():
          final reauth = await _apple.reauthenticate(nonce: challenge.nonce);
          switch (reauth) {
            case AppleReauthCancelled():
              _gateway.close(_op);
              return const DeletionFlowCancelled();
            case AppleReauthFailed():
              return const DeletionFlowFailed(retryable: true);
            case AppleReauthGranted():
              _requested = true;
              return await _settle(await _gateway.request(_op,
                  challengeId: challenge.challengeId,
                  challengeResponse: reauth.challengeResponse));
          }
      }
    } finally {
      _busy = false;
    }
  }

  @override
  Future<DeletionFlowResult> checkStatus() async {
    if (_busy) return const DeletionFlowUnconfirmed(canCheckStatus: true);
    _busy = true;
    try {
      return await _settle(await _gateway.recover(_op));
    } finally {
      _busy = false;
    }
  }

  @override
  void close() => _gateway.close(_op);

  Future<DeletionFlowResult> _settle(PreparedDeletionOutcome outcome) async {
    switch (outcome) {
      case PreparedDeletionRemoteCompletion():
        // The exact evidence, once; local removal is bound to the ORIGINAL
        // owner, so an account switched in the meantime is never touched.
        final local = await _gateway.removeOriginalLocalReplica(outcome);
        return local == PreparedLocalRemovalOutcome.originalLocalRemovalConfirmed
            ? const DeletionFlowCompleted()
            : const DeletionFlowLocalCleanupPending();
      case PreparedDeletionPending():
        return const DeletionFlowPending();
      case PreparedDeletionUnconfirmed(:final reason):
        return DeletionFlowUnconfirmed(
            canCheckStatus: switch (reason) {
          PreparedDeletionUnconfirmedReason.protocolUnconfirmed ||
          PreparedDeletionUnconfirmedReason.receiptStoreUnavailable ||
          PreparedDeletionUnconfirmedReason.receiptChanged =>
            true,
          PreparedDeletionUnconfirmedReason.staleContext ||
          PreparedDeletionUnconfirmedReason.foreignOperation ||
          PreparedDeletionUnconfirmedReason.operationClosed =>
            false,
        });
    }
  }
}
