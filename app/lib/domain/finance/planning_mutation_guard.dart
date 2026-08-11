/// MALI-026 (Phase-8 B8-2.9) — central P1 planning mutation contract.
///
/// Intended call sites when v30 planning persistence is activated: every
/// budget/goal/goal-contribution create; edit-money; delete; contribution or
/// withdrawal; auto-save; notification-driven planning mutation; import
/// planning mutation; sync-applied planning write; and direct repository
/// financial write. Navigation, restore, sync/parking, and the future cutover
/// executor consume the same PlanningCutoverCoordinator rather than interpreting
/// schema columns themselves.
///
/// B8-2.9 deliberately does not wire this guard into today's repositories:
/// schema v29 resolves to legacy, and production behavior remains unchanged.
library;

import '../../data/db/planning_cutover.dart';

/// Typed signal that planning repair must complete before a P1 write proceeds.
class PlanningCurrencyRepairRequired implements Exception {
  const PlanningCurrencyRepairRequired([
    this.message =
        'Planning currency repair is required before changing planning rows.',
  ]);

  final String message;

  @override
  String toString() => 'PlanningCurrencyRepairRequired: $message';
}

class PlanningMutationGuard {
  const PlanningMutationGuard(this._coordinator);

  final PlanningCutoverCoordinator _coordinator;

  /// Blocks every planning financial mutation only during unresolved P1.
  void requireMutable() => _requireResolved();

  /// Chosen delete policy: block planning-row deletion during unresolved P1.
  ///
  /// Deleting a budget/goal changes the repair fingerprint, so allowing it while
  /// repair is unresolved could invalidate the decision being confirmed.
  void requireDeletable() => _requireResolved();

  void _requireResolved() {
    if (_coordinator.state() == PlanningCutoverState.unresolved) {
      throw const PlanningCurrencyRepairRequired();
    }
  }
}
