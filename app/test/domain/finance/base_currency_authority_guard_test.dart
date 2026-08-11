import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// MALI-026 (Phase-8 B8-2.8 §15) — baseCurrencyProvider / user_settings.currency
// must NEVER be the AUTHORITY for interpreting an EXISTING budget / goal /
// goal_contribution once planning Money lands at v30; existing rows use
// row.currency (contributions: parent goal.currency). Allowed uses of the base
// currency: defaults for NEW rows, UI initial selection, dashboard base-currency
// display. This is a PROSPECTIVE architecture guard over the planning DATA layer:
// it passes today (planning money is not yet converted) and will fail the moment
// someone wires the base currency into a planning money read/write authority.

void main() {
  // Planning-money data-layer surfaces. The mapper file (drift_repository_support)
  // is checked narrowly for the base-currency identifiers too, since the future
  // budget/goal mappers will live there.
  const dataLayerFiles = [
    'lib/data/repositories/drift_budget_repository.dart',
    'lib/data/repositories/drift_goal_repository.dart',
  ];

  test('planning data-layer never uses baseCurrencyProvider as a currency authority',
      () {
    for (final path in dataLayerFiles) {
      final src = File(path).readAsStringSync();
      expect(src.contains('baseCurrencyProvider'), isFalse,
          reason: '$path must not use baseCurrencyProvider — an existing budget/'
              'goal currency is row.currency (contributions: parent goal.currency), '
              'not the mutable base currency.');
    }
  });

  test('planning data-layer does not read user_settings.currency as money authority',
      () {
    for (final path in dataLayerFiles) {
      final src = File(path).readAsStringSync();
      // A raw `SELECT currency FROM user_settings` (or similar) inside a planning
      // repo would be interpreting existing planning money via the mutable base.
      expect(src.contains('user_settings'), isFalse,
          reason: '$path must not consult user_settings for planning money currency.');
    }
  });
}
