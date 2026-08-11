/// MALI-026 (Phase-8 B8-2.9) — the single runtime authority seam for the
/// planning-currency cutover.
///
/// Every future cutover-aware subsystem (mutation/navigation, sync parking,
/// restore preflight, and the cutover executor) must consume this coordinator.
/// No subsystem may infer authority by inspecting schema columns independently.
enum PlanningCutoverState {
  /// Schema v29 and its existing legacy planning-money behavior.
  legacy,

  /// Future v30 structure exists, but repair/cutover is not complete (P1).
  unresolved,

  /// The future durable marker and exact postflight establish P3 authority.
  canonical,
}

abstract class PlanningCutoverCoordinator {
  PlanningCutoverState state();
}

/// Production coordinator for the CURRENT schema-v29 application.
///
/// v29 has neither canonical planning columns nor a durable cutover marker, so
/// its only truthful state is [PlanningCutoverState.legacy]. At v30 this
/// implementation will be replaced with the DB-backed mapping:
///
/// - marker `0` (or no valid canonical data) -> `unresolved`;
/// - marker `1` plus a valid exact postflight -> `canonical`.
///
/// No real marker is read or added in schema v29.
class SchemaV29PlanningCutoverCoordinator
    implements PlanningCutoverCoordinator {
  const SchemaV29PlanningCutoverCoordinator();

  @override
  PlanningCutoverState state() => PlanningCutoverState.legacy;
}

/// Injectable coordinator for tests and future-state simulations.
class FixedPlanningCutoverCoordinator implements PlanningCutoverCoordinator {
  const FixedPlanningCutoverCoordinator(this.fixedState);

  final PlanningCutoverState fixedState;

  @override
  PlanningCutoverState state() => fixedState;
}
