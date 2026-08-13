// MALI-026 (Phase-9F §3) — architecture/contract guard: EVERY canonical remote
// write surface for user_budgets / user_goals MUST persist the row's own currency,
// and MUST defer (never send) a NULL-currency row. This is a source-contract test
// (the canonical write surfaces are few and enumerated here); a behavioural null
// defer test lives alongside. If a NEW canonical budget/goal write surface is added,
// add it to `_canonicalWriteSurfaces` and it must satisfy the same contract.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String rel) => File(rel).readAsStringSync();

/// The enumerated canonical budget/goal remote-write surfaces (the ONLY code paths
/// that may push these rows to the server in canonical/P3 mode).
const _canonicalWriteSurfaces = <String>[
  'lib/features/planning_sync/services/planning_primary_backfill_service.dart',
  'lib/features/planning_sync/services/planning_outbox_queue.dart',
];

/// Slice a source string to the region of a named helper/loop so assertions are
/// scoped to the right payload.
String _slice(String src, String startMarker, String endMarker) {
  final s = src.indexOf(startMarker);
  expect(s, greaterThanOrEqualTo(0), reason: 'marker not found: $startMarker');
  final e = src.indexOf(endMarker, s);
  expect(e, greaterThan(s), reason: 'end marker not found: $endMarker');
  return src.substring(s, e);
}

void main() {
  test('WS-5: backfill budget insert payload persists currency', () {
    final src = _read(_canonicalWriteSurfaces[0]);
    final budget = _slice(src, "table: 'user_budgets'", 'created: created');
    expect(budget, contains("'currency': currency"),
        reason: 'canonical budget backfill must send the row currency');
  });

  test('WS-5: backfill goal insert payload persists currency', () {
    final src = _read(_canonicalWriteSurfaces[0]);
    final goal = _slice(src, "table: 'user_goals'", 'created: created');
    expect(goal, contains("'currency': currency"),
        reason: 'canonical goal backfill must send the row currency');
  });

  test('WS-5: backfill DEFERS a NULL-currency budget/goal (fail-closed, no send)',
      () {
    final src = _read(_canonicalWriteSurfaces[0]);
    // Both loops read the row currency and `continue` (defer) when it is null,
    // recording an explicit unrepaired failure — never sending currency: null.
    final budgetDefer = _slice(src, "table: 'user_budgets'", 'created: created');
    final goalDefer = _slice(src, "table: 'user_goals'", 'created: created');
    for (final region in [
      src.substring(0, src.indexOf("table: 'user_budgets'")),
      src.substring(0, src.indexOf("table: 'user_goals'")),
    ]) {
      // the defer guard appears BEFORE each _insertParent payload
      expect(region, contains('if (currency == null)'));
      expect(region, contains('planning_currency_unrepaired'));
    }
    // and the payloads themselves never hardcode a null currency
    expect(budgetDefer, isNot(contains("'currency': null")));
    expect(goalDefer, isNot(contains("'currency': null")));
  });

  test('canonical push builder emits currency for budgets AND goals', () {
    final src = _read(_canonicalWriteSurfaces[1]);
    // planning_outbox_queue.dart canonical branch: `if (canonical) 'currency': ...`
    expect(src, contains("if (canonical) 'currency': budget.currency"),
        reason: 'canonical budget push must carry currency');
    expect(src, contains("if (canonical) 'currency': goal.currency"),
        reason: 'canonical goal push must carry currency');
  });

  test('NO canonical budget/goal write surface omits currency (contract lock)', () {
    // Guard against silent regression: every enumerated surface must reference a
    // currency key for the planning parents. (A new surface that forgets currency
    // fails here, forcing the author to satisfy the WS-5 invariant.)
    for (final path in _canonicalWriteSurfaces) {
      final src = _read(path);
      expect(src.contains("'currency'"), isTrue,
          reason: '$path: a canonical planning write must reference currency');
    }
  });
}
