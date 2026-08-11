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
