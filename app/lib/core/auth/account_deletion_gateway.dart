import 'account_deletion_service.dart';

/// Where an account deletion stands, as reported by the backend that performs it.
///
/// Only [AccountDeletionCompleted] means the account is gone. Every other state
/// is either work still happening or a failure, and the UI must never present
/// them as a finished deletion.
sealed class AccountDeletionState {
  const AccountDeletionState();
}

/// The request was received (for example, scheduled) but is NOT completed.
final class AccountDeletionAccepted extends AccountDeletionState {
  const AccountDeletionAccepted({this.scheduledFor});

  /// When the backend says the deletion will happen, if it says.
  final DateTime? scheduledFor;
}

/// The deletion is being carried out right now.
final class AccountDeletionInProgress extends AccountDeletionState {
  const AccountDeletionInProgress();
}

/// The server confirmed the account was deleted. The ONLY success.
final class AccountDeletionCompleted extends AccountDeletionState {
  const AccountDeletionCompleted();
}

/// The deletion did not happen. [retryable] says whether trying again can help.
final class AccountDeletionFailed extends AccountDeletionState {
  const AccountDeletionFailed({required this.retryable});
  final bool retryable;
}

/// The seam between the Delete account screen and whatever backend performs the
/// deletion. An implementation reports truthfully: it emits
/// [AccountDeletionCompleted] only after the server has confirmed completion.
abstract interface class AccountDeletionGateway {
  /// Whether starting this deletion removes the account right away. The
  /// confirmation copy follows it so it never promises more than the backend does.
  bool get deletesImmediately;

  /// Starts (or resumes) the deletion and reports its progress. The stream's
  /// last state is the outcome; a stream that ends without
  /// [AccountDeletionCompleted] is not a success.
  Stream<AccountDeletionState> delete();
}

/// Delegates to the EXISTING scheduled-deletion service and reports what it
/// actually achieved: the request is [AccountDeletionAccepted] (scheduled), never
/// [AccountDeletionCompleted]. The immediate-deletion adapter replaces this one.
class ScheduledAccountDeletionGateway implements AccountDeletionGateway {
  const ScheduledAccountDeletionGateway(this._service);

  final AccountDeletionService _service;

  @override
  bool get deletesImmediately => false;

  @override
  Stream<AccountDeletionState> delete() async* {
    yield const AccountDeletionInProgress();
    final DateTime? scheduledFor;
    try {
      scheduledFor = await _service.requestDeletion();
    } catch (_) {
      yield const AccountDeletionFailed(retryable: true);
      return;
    }
    if (scheduledFor == null) {
      // Nothing to schedule against (no account backend): nothing was requested.
      yield const AccountDeletionFailed(retryable: false);
      return;
    }
    yield AccountDeletionAccepted(scheduledFor: scheduledFor);
  }
}
