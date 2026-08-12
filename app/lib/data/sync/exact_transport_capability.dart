/// MALI-026 (Phase-8 B8-2.9) — the single exact-money transport capability
/// model. Push and pull are intentionally tracked independently: proving one
/// direction says nothing about the other.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db/planning_cutover.dart';

enum ExactTransportCapability {
  unknown,
  verifiedExact,
  unsupported,
}

/// Live PostgREST decimal-string -> NUMERIC push has not been verified.
final exactPushTransportCapabilityProvider =
    Provider<ExactTransportCapability>((ref) {
  return ExactTransportCapability.unknown;
});

/// Live PostgREST NUMERIC::text pull has not been verified.
final exactPullTransportCapabilityProvider =
    Provider<ExactTransportCapability>((ref) {
  return ExactTransportCapability.unknown;
});

/// MALI-026 (B8-3 §30) — whether the SERVER supports per-row PLANNING currency
/// (`user_budgets.currency` / `user_goals.currency`, migration 0077). This is a
/// SEPARATE, truthful capability: budgets/goals cannot be pushed or pulled
/// canonically until the server carries their currency, independent of the exact
/// decimal-string transport capability. It is UNKNOWN until externally verified —
/// NEVER inferred from the local schema version or local canonical (P3) state
/// (0077 is undeployed, so this stays unknown and planning cloud sync stays
/// parked/deferred).
final planningServerCurrencyCapabilityProvider =
    Provider<ExactTransportCapability>((ref) {
  return ExactTransportCapability.unknown;
});

/// MALI-026 (B8-3 §30) — the weaker of two independent capabilities:
/// [verifiedExact] ONLY when BOTH are verified; [unsupported] if either is
/// unsupported; otherwise [unknown]. Canonical planning budgets/goals PUSH needs
/// TWO capabilities at once — the exact decimal-string transport AND the SERVER
/// per-row currency column (0077) — so it must stay parked unless BOTH are
/// verified (never unpark on one alone).
ExactTransportCapability weakerCapability(
  ExactTransportCapability a,
  ExactTransportCapability b,
) {
  if (a == ExactTransportCapability.unsupported ||
      b == ExactTransportCapability.unsupported) {
    return ExactTransportCapability.unsupported;
  }
  if (a == ExactTransportCapability.verifiedExact &&
      b == ExactTransportCapability.verifiedExact) {
    return ExactTransportCapability.verifiedExact;
  }
  return ExactTransportCapability.unknown;
}

/// MALI-026 (B8-3 §29/§30) — whether a canonical PLANNING money entity
/// (budgets/goals/goal_contributions) may cloud-sync in ONE direction.
///
/// A non-planning-gated entity is always allowed here (this gate says nothing
/// about it — scenario 6). A planning-gated entity syncs ONLY when the SERVER
/// carries per-row planning currency (0077) AND the exact decimal transport for
/// THAT direction is verified — both, never one alone, and NEVER inferred from
/// the local schema version or local canonical (P3) state. Both are UNKNOWN
/// today, so planning cloud sync stays fully deferred in either direction.
bool planningMoneyEntitySyncEnabled({
  required bool isPlanningCurrencyGatedEntity,
  required ExactTransportCapability planningCurrencyCapability,
  required ExactTransportCapability transportCapability,
}) {
  if (!isPlanningCurrencyGatedEntity) return true;
  return weakerCapability(planningCurrencyCapability, transportCapability) ==
      ExactTransportCapability.verifiedExact;
}

/// Durable reason future outbox wiring records when an exact push is parked.
const String exactMoneyTransportUnverifiedReason =
    'exact_money_transport_unverified';

/// Whether an exact-money remote mutation must be parked.
///
/// Only canonical authority requires exact transport. Legacy v29 retains its
/// current JSON-number compatibility behavior for every capability value. The
/// unresolved state owns no canonical money writes (the mutation guard blocks
/// them), so it also does not activate exact-money parking here. When this
/// returns true, future outbox wiring must retain the local canonical write and
/// remote mutation durably with [exactMoneyTransportUnverifiedReason]: do not
/// serialize through the legacy JSON-number adapter, mark it synced, drop it, or
/// aggressively retry it.
bool shouldParkExactMoneyWrite({
  required PlanningCutoverState cutoverState,
  required ExactTransportCapability pushCapability,
}) {
  return cutoverState == PlanningCutoverState.canonical &&
      pushCapability != ExactTransportCapability.verifiedExact;
}
