import 'dart:async';

import '../../data/db/app_database.dart';
import '../../features/capture/services/ledger_outbox_queue.dart';
import '../../features/planning_sync/services/planning_outbox_queue.dart';

/// What a Retry re-armed. Counts only.
class SyncRetryResult {
  const SyncRetryResult({
    this.deadLettersRearmed = 0,
    this.authParkedRearmed = 0,
    this.mappingsRearmed = 0,
  });

  final int deadLettersRearmed;
  final int authParkedRearmed;
  final int mappingsRearmed;

  int get total => deadLettersRearmed + authParkedRearmed + mappingsRearmed;
}

/// A-5 — user/event-triggered recovery of stuck sync work.
///
/// Two entry points:
///  * [rearmAuthParked] — an authenticated session / token refresh arrived.
///    Only the rows parked `auth_required` return to the queue (they never
///    consumed an attempt).
///  * [retryNow] — the user pressed Retry. Re-arms retryable dead letters (NOT
///    business-rule duplicates or unsupported operations), auth-parked rows and
///    terminally failed sender mappings, drops pending backoff waits, forces a
///    capability re-probe and wakes the sync orchestrator.
class SyncRecoveryService {
  SyncRecoveryService({
    required AppDatabase db,
    required LedgerOutboxQueue ledgerQueue,
    required PlanningOutboxQueue planningQueue,
    required Future<void> Function() reprobeCapabilities,
    required void Function() wakeup,
  })  : _db = db,
        _ledger = ledgerQueue,
        _planning = planningQueue,
        _reprobe = reprobeCapabilities,
        _wakeup = wakeup;

  final AppDatabase _db;
  final LedgerOutboxQueue _ledger;
  final PlanningOutboxQueue _planning;
  final Future<void> Function() _reprobe;
  final void Function() _wakeup;

  /// Re-arms rows parked for authentication and wakes the orchestrator when any
  /// came back.
  Future<int> rearmAuthParked() async {
    final n = await _ledger.reArmAuthParked() + await _planning.reArmAuthParked();
    if (n > 0) _wakeup();
    return n;
  }

  Future<SyncRetryResult> retryNow() async {
    final deadLetters = await _ledger.reArmRetryableDeadLetters() +
        await _planning.reArmRetryableDeadLetters();
    final auth =
        await _ledger.reArmAuthParked() + await _planning.reArmAuthParked();
    await _ledger.clearRetryBackoff();
    await _planning.clearRetryBackoff();
    // Terminal (and backing-off) sender mappings get a clean retry state.
    final mappings = await _db.customUpdate(
      "UPDATE sender_bank_mappings SET sync_status = 'pending', "
      'sync_permanent = 0, sync_attempt_count = 0, sync_next_retry_at = NULL, '
      "sync_failure_class = NULL WHERE sync_status = 'failed';",
    );
    // D-4: an auth rejection backs a pending mapping off without failing it.
    await _db.customStatement(
      'UPDATE sender_bank_mappings SET sync_next_retry_at = NULL '
      "WHERE sync_status = 'pending' AND sync_next_retry_at IS NOT NULL;",
    );
    try {
      await _reprobe();
    } catch (_) {
      // A failed probe is simply "still unknown"; Retry must not throw.
    }
    _wakeup();
    return SyncRetryResult(
      deadLettersRearmed: deadLetters,
      authParkedRearmed: auth,
      mappingsRearmed: mappings,
    );
  }
}

/// Re-arms auth-parked rows on every [AuthSessionValid] event (sign-in, initial
/// session, token refresh). The caller owns the returned subscription.
StreamSubscription<void> bindAuthRearm(
  Stream<void> events,
  SyncRecoveryService recovery,
) =>
    events.listen((_) => unawaited(recovery.rearmAuthParked().catchError((_) => 0)));
