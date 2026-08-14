/// MALI-026 (Phase-9M) — cardinality contract for a GUARDED PATCH/UPDATE whose
/// predicate makes BOTH 0 and 1 matched rows legitimate control flow: the server
/// revision CAS (`WHERE id = X AND revision = R`), the optimistic `updated_at`
/// guard, the not-already-deleted tombstone guard, and the `currency IS NULL`
/// first-writer-wins repair.
///
/// Such a mutation MUST decode the LIST representation (`Prefer: return=…` gives
/// the affected rows as an array) and NEVER `.maybeSingle()`. Against a newer
/// PostgREST, `.maybeSingle()` on a 0-row PATCH throws `PGRST116` — a
/// singular-cardinality error whose wording varies by version (proved live in
/// Phase 9L: postgrest-dart 2.7.1 matches "Results contain 0 rows" but the server
/// returns "The result contains 0 rows"). That is NOT a conflict; classifying it
/// as one (or matching brittle English) is forbidden.
///
/// The cardinality is explicit and version-independent:
///   • 0 rows  → null    — the expected zero-match branch (conflict / classifier).
///   • 1 row   → the row — mutation accepted; decode the ACK.
///   • >1 rows → throws  — a data-integrity INVARIANT violation. A guarded
///     predicate anchored on a primary key can match at most one row; more is
///     corruption. This is NEVER a conflict and the first row is NEVER silently
///     chosen.
///
/// This helper only interprets a SUCCESSFUL PATCH's returned-row list. It never
/// runs the request and never swallows a transport/auth/server exception — those
/// propagate to the caller's existing error classification unchanged.
library;

/// Thrown when a guarded mutation matched more than one row — a hard invariant
/// violation, distinct from both a conflict and a transport error.
class GuardedMutationCardinalityError extends StateError {
  GuardedMutationCardinalityError(this.surface, this.rowCount)
      : super('guarded mutation cardinality invariant violated: "$surface" '
            'matched $rowCount rows (a PK-guarded predicate must match 0 or 1)');

  final String surface;
  final int rowCount;
}

/// Interpret the affected-row LIST of a guarded PATCH/UPDATE: 0 → null, 1 → the
/// row, >1 → [GuardedMutationCardinalityError]. [surface] names the call site
/// for diagnostics. See the library doc for why this replaces `.maybeSingle()`.
Map<String, dynamic>? guardedAck(List<dynamic> rows, String surface) {
  if (rows.isEmpty) return null;
  if (rows.length == 1) {
    return Map<String, dynamic>.from(rows.first as Map);
  }
  throw GuardedMutationCardinalityError(surface, rows.length);
}
