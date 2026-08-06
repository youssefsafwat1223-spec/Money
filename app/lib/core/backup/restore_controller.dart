import 'package:flutter/foundation.dart';

import 'restore_plan.dart';
import 'restore_result.dart';

// MALI-014 / MALI-076n (Batch-5 closure) §Blocker-5 — the truthful restore
// state machine. It does NOT redesign the screen; it gives the UI an accurate,
// privacy-safe phase to render, ENFORCES an explicit final confirmation after
// preparation succeeds and before any destructive mutation, guarantees cancellation
// before mutation changes nothing, and shows success only after the mutation has
// committed + verified + reopened. It carries only safe fields — never a raw error,
// path, passphrase, SQL, or financial value.

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
  reopening,
  completed,
  cancelled,
  failedWithoutChanges,
  recoveryRequired,
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
  final String? message; // safe, user-presentable
  final String? operationId;

  RestoreUiState copyWith({
    RestoreUiPhase? phase,
    List<String>? warnings,
    String? message,
    String? operationId,
  }) =>
      RestoreUiState(
        phase: phase ?? this.phase,
        warnings: warnings ?? this.warnings,
        message: message ?? this.message,
        operationId: operationId ?? this.operationId,
      );
}

class RestoreController extends ValueNotifier<RestoreUiState> {
  RestoreController({
    required Future<RestorePlan> Function() prepare,
    required Future<RestoreResult> Function(RestorePlan plan) mutate,
    Future<void> Function(String operationId)? acknowledge,
  })  : _prepare = prepare,
        _mutate = mutate,
        _acknowledge = acknowledge,
        super(const RestoreUiState(phase: RestoreUiPhase.idle));

  final Future<RestorePlan> Function() _prepare;
  final Future<RestoreResult> Function(RestorePlan plan) _mutate;
  final Future<void> Function(String operationId)? _acknowledge;

  RestorePlan? _plan;
  bool _cancelled = false;

  /// Phase 1 — download / decrypt / validate / build the plan. Mutates NOTHING.
  /// Ends at [RestoreUiPhase.readyForConfirmation] (the confirmation gate) or a
  /// failure state that leaves the database unchanged.
  Future<void> beginPreparation() async {
    _cancelled = false;
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
    } catch (_) {
      // Preparation never mutates → the database is unchanged.
      value = const RestoreUiState(
        phase: RestoreUiPhase.failedWithoutChanges,
        message: 'تعذّر تجهيز الاستعادة. تحقّق من الملف وكلمة المرور.',
      );
    }
  }

  /// Cancel BEFORE the destructive mutation — nothing changes. Ignored once the
  /// transaction has begun (the mutation completes or rolls back atomically).
  void cancel() {
    if (value.phase == RestoreUiPhase.restoring ||
        value.phase == RestoreUiPhase.verifying ||
        value.phase == RestoreUiPhase.reopening ||
        value.phase == RestoreUiPhase.completed) {
      return;
    }
    _cancelled = true;
    value = const RestoreUiState(phase: RestoreUiPhase.cancelled);
  }

  /// Phase 2 — the user's explicit confirmation. Only from
  /// [RestoreUiPhase.readyForConfirmation]. Runs the destructive mutation through
  /// the file-exclusive maintenance primitive and shows success ONLY after commit +
  /// verification + reopen succeed; on any failure the pre-restore data is intact.
  Future<void> confirm() async {
    final plan = _plan;
    if (value.phase != RestoreUiPhase.readyForConfirmation || plan == null) {
      return; // confirmation is required and single-use
    }
    value = const RestoreUiState(phase: RestoreUiPhase.waitingForDatabase);
    value = const RestoreUiState(phase: RestoreUiPhase.restoring);
    final RestoreResult result;
    try {
      result = await _mutate(plan);
    } catch (_) {
      value = const RestoreUiState(
        phase: RestoreUiPhase.failedWithoutChanges,
        message: 'تعذّرت الاستعادة ولم تتغيّر بياناتك الحالية.',
      );
      return;
    }
    value = _mapOutcome(result, plan);
    if (result.isCommitted && result.operationId != null) {
      // Acknowledge only AFTER the completed state is shown — idempotent.
      await _acknowledge?.call(result.operationId!);
    }
  }

  RestoreUiState _mapOutcome(RestoreResult result, RestorePlan plan) {
    switch (result.outcome) {
      case RestoreOutcome.success:
      case RestoreOutcome.committedPendingAcknowledgement:
        return RestoreUiState(
          phase: RestoreUiPhase.completed,
          warnings: plan.warnings,
          operationId: result.operationId,
        );
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
