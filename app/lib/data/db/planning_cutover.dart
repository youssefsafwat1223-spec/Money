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

/// MALI-026 (Phase-8 B8-3 §10) — thrown when the durable marker claims canonical
/// but the planning data is not actually canonical (a NULL currency/minor on a
/// non-null planning amount). This is an INVARIANT failure, never silently healed.
class PlanningCutoverInvariantException implements Exception {
  const PlanningCutoverInvariantException(this.message);
  final String message;
  @override
  String toString() => 'PlanningCutoverInvariantException: $message';
}

/// MALI-026 (Phase-8 B8-3 §10) — the REAL v30-aware cutover state, derived from
/// the durable DB marker + a postflight validation. Kept OUTSIDE the coordinator
/// class so it can be computed once at bootstrap (async) and cached in a
/// [DbBackedPlanningCutoverCoordinator]; re-run after the cutover executor commits.
///
/// - `userVersion < 30`            -> legacy (no v30 structure; never at runtime
///                                     in a v30 build, but the contract is explicit);
/// - v30 + marker 0                -> unresolved (P1: repair not complete);
/// - v30 + marker 1 + valid data   -> canonical (P3);
/// - v30 + marker 1 + INVALID data -> throws [PlanningCutoverInvariantException]
///                                     (a canonical marker over non-canonical rows).
///
/// Canonical is NEVER inferred from column existence alone (§10): the durable
/// marker is the authority, and marker=1 is corroborated by the postflight.
Future<PlanningCutoverState> computePlanningCutoverState(
  Future<int> Function() readUserVersion,
  Future<int> Function() readMarker,
  Future<int> Function() countCanonicalViolations,
) async {
  final version = await readUserVersion();
  if (version < 30) return PlanningCutoverState.legacy;
  final marker = await readMarker();
  if (marker != 1) return PlanningCutoverState.unresolved;
  final violations = await countCanonicalViolations();
  if (violations > 0) {
    throw PlanningCutoverInvariantException(
      'planning_cutover_state=canonical but $violations planning row(s) lack a '
      'currency/minor — refusing to treat a corrupt dataset as canonical',
    );
  }
  return PlanningCutoverState.canonical;
}

/// A coordinator holding a state resolved from the DB at bootstrap and refreshed
/// after the cutover executor commits (P2 -> P3), so the guard/nav/parking react
/// to the real durable authority without an app restart.
class DbBackedPlanningCutoverCoordinator implements PlanningCutoverCoordinator {
  DbBackedPlanningCutoverCoordinator({
    required PlanningCutoverState initialState,
    required Future<int> Function() readUserVersion,
    required Future<int> Function() readMarker,
    required Future<int> Function() countCanonicalViolations,
  })  : _state = initialState,
        _readUserVersion = readUserVersion,
        _readMarker = readMarker,
        _countViolations = countCanonicalViolations;

  PlanningCutoverState _state;
  final Future<int> Function() _readUserVersion;
  final Future<int> Function() _readMarker;
  final Future<int> Function() _countViolations;

  @override
  PlanningCutoverState state() => _state;

  /// Correction 2 — after the cutover commits (or on demand), INDEPENDENTLY
  /// recompute the state from the persisted DB (user_version + marker + canonical
  /// violations), never from a caller-asserted value. Throws
  /// [PlanningCutoverInvariantException] if the marker claims canonical over a
  /// non-canonical dataset; never silently downgrades or forces canonical.
  Future<PlanningCutoverState> refreshFromDatabase() async {
    _state = await computePlanningCutoverState(
        _readUserVersion, _readMarker, _countViolations);
    return _state;
  }
}
