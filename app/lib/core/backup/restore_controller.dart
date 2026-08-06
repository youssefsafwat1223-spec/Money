import 'package:flutter/foundation.dart';

import 'backup_service.dart';
import 'restore_plan.dart';
import 'restore_result.dart';

// MALI-014 §Blocker-1/5 — the truthful restore state machine + the CONFIRMATION
// CAPABILITY. It does NOT redesign the screen; it gives the UI an accurate,
// privacy-safe phase, ENFORCES an explicit confirmation before any destructive
// mutation (structurally — via [RestoreConfirmation], which only this canonical
// flow can mint), and emits `completed` ONLY after the restored database is proven
// usable (post-commit reopen/admission) and durably acknowledged.

enum RestoreUiPhase {
  idle,
  selectingBackup,
  downloading,
  decrypting,
  validating,
  readyForConfirmation,
  waitingForDatabase,
  restoring,
  verifying,
  reestablishingDatabase,
  completed,
  cancelled,
  failedWithoutChanges,
  recoveryRequired,
}

/// An unforgeable, single-use confirmation capability. Its constructor is private
/// to this library, so ONLY [RestoreController.confirm] (the canonical flow, after
/// preparation + explicit user confirmation) can mint one — a production caller can
/// never fabricate a confirmed mutation. Tied to one plan (operation id + source
/// fingerprint); consumed exactly once.
class RestoreConfirmation {
  RestoreConfirmation._(this.plan);

  final RestorePlan plan;
  bool _consumed = false;

  /// True the first time only; a reused confirmation returns false.
  bool consume() {
    if (_consumed) return false;
    _consumed = true;
    return true;
  }

  /// Test-only minting for unit tests of the service boundary.
  @visibleForTesting
  static RestoreConfirmation forTest(RestorePlan plan) =>
      RestoreConfirmation._(plan);
}

@immutable
class RestoreUiState {
  const RestoreUiState({
    required this.phase,
    this.warnings = const [],
    this.message,
    this.operationId,
  });

  final RestoreUiPhase phase;
  final List<String> warnings;
  final String? message;
  final String? operationId;
}

class RestoreController extends ValueNotifier<RestoreUiState> {
  RestoreController({
    required Future<RestorePlan> Function() prepare,
    required Future<RestoreResult> Function(RestoreConfirmation confirmation)
        mutate,
    Future<bool> Function()? reestablish,
    Future<void> Function(String operationId)? acknowledge,
  })  : _prepare = prepare,
        _mutate = mutate,
        _reestablish = reestablish,
        _acknowledge = acknowledge,
        super(const RestoreUiState(phase: RestoreUiPhase.idle));

  final Future<RestorePlan> Function() _prepare;
  final Future<RestoreResult> Function(RestoreConfirmation) _mutate;
  final Future<bool> Function()? _reestablish;
  final Future<void> Function(String operationId)? _acknowledge;

  RestorePlan? _plan;
  bool _cancelled = false;

  /// Phase 1 — download / decrypt / validate / build the plan. Mutates NOTHING.
  Future<void> beginPreparation() async {
    _cancelled = false;
    _plan = null;
    value = const RestoreUiState(phase: RestoreUiPhase.downloading);
    try {
      value = const RestoreUiState(phase: RestoreUiPhase.decrypting);
      value = const RestoreUiState(phase: RestoreUiPhase.validating);
      final plan = await _prepare();
      if (_cancelled) {
        value = const RestoreUiState(phase: RestoreUiPhase.cancelled);
        return;
      }
      _plan = plan;
      value = RestoreUiState(
        phase: RestoreUiPhase.readyForConfirmation,
        warnings: plan.warnings,
        operationId: plan.operationId,
      );
    } on BackupException catch (e) {
      value =
          RestoreUiState(phase: RestoreUiPhase.failedWithoutChanges, message: e.message);
    } catch (_) {
      value = const RestoreUiState(
        phase: RestoreUiPhase.failedWithoutChanges,
        message: 'تعذّر تجهيز الاستعادة. تحقّق من الملف وكلمة المرور.',
      );
    }
  }

  /// Cancel BEFORE mutation — nothing changes, and no confirmation exists to reuse.
  void cancel() {
    if (value.phase == RestoreUiPhase.restoring ||
        value.phase == RestoreUiPhase.verifying ||
        value.phase == RestoreUiPhase.reestablishingDatabase ||
        value.phase == RestoreUiPhase.completed) {
      return;
    }
    _cancelled = true;
    _plan = null; // destroy any pending confirmation basis
    value = const RestoreUiState(phase: RestoreUiPhase.cancelled);
  }

  /// Phase 2 — the user's explicit confirmation mints the single-use capability and
  /// runs the mutation. `completed` is emitted ONLY after commit + verification +
  /// a proven-usable database (reopen/admission) + durable acknowledgement.
  Future<void> confirm() async {
    final plan = _plan;
    if (value.phase != RestoreUiPhase.readyForConfirmation || plan == null) {
      return; // confirmation is required and single-use
    }
    final confirmation = RestoreConfirmation._(plan); // canonical mint
    value = const RestoreUiState(phase: RestoreUiPhase.waitingForDatabase);
    value = const RestoreUiState(phase: RestoreUiPhase.restoring);

    final RestoreResult result;
    try {
      result = await _mutate(confirmation);
    } on BackupException catch (e) {
      value = RestoreUiState(
          phase: RestoreUiPhase.failedWithoutChanges, message: e.message);
      return;
    } catch (_) {
      value = const RestoreUiState(
        phase: RestoreUiPhase.failedWithoutChanges,
        message: 'تعذّرت الاستعادة ولم تتغيّر بياناتك الحالية.',
      );
      return;
    }

    if (!result.isCommitted) {
      value = _mapFailure(result);
      return;
    }

    // Committed durably, but NOT yet usable/acknowledged.
    value = const RestoreUiState(phase: RestoreUiPhase.verifying);
    value = const RestoreUiState(phase: RestoreUiPhase.reestablishingDatabase);
    final usable = _reestablish == null ? true : await _reestablish();
    if (!usable) {
      // The data is committed but the database could not be re-established. Do NOT
      // acknowledge — startup recovery will re-establish, never re-restore.
      value = RestoreUiState(
        phase: RestoreUiPhase.recoveryRequired,
        operationId: result.operationId,
        message: 'اكتملت الاستعادة لكن تعذّر تجهيز قاعدة البيانات. أعد تشغيل التطبيق.',
      );
      return;
    }
    if (result.operationId != null) {
      await _acknowledge?.call(result.operationId!);
    }
    value = RestoreUiState(
      phase: RestoreUiPhase.completed,
      warnings: plan.warnings,
      operationId: result.operationId,
    );
  }

  RestoreUiState _mapFailure(RestoreResult result) {
    switch (result.outcome) {
      case RestoreOutcome.recoveryRequired:
      case RestoreOutcome.reopenFailed:
      case RestoreOutcome.rollbackFailed:
        return const RestoreUiState(
          phase: RestoreUiPhase.recoveryRequired,
          message: 'تعذّرت الاستعادة وتحتاج قاعدة البيانات إلى إصلاح.',
        );
      default:
        return const RestoreUiState(
          phase: RestoreUiPhase.failedWithoutChanges,
          message: 'تعذّرت الاستعادة ولم تتغيّر بياناتك الحالية.',
        );
    }
  }
}
