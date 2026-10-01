import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Two rules that keep the threshold honest.
void main() {
  test('no runtime code decides a budget warning from a constant', () {
    // The number lived in two places before this feature: 0.75 in the alert
    // planner and 0.8 in the progress use case. They disagreed, so a budget
    // could show a warning bar with no alert sent, or the reverse. Both now
    // read `budget.alertThresholdPercent`.
    //
    // Scoped to the two files that own the decision; a threshold comparison
    // reappearing in either is the regression this catches.
    const owners = <String>[
      'lib/domain/services/budget_alert_planner.dart',
      'lib/domain/usecases/budget_progress_usecase.dart',
    ];
    final offenders = <String>[];
    for (final path in owners) {
      final lines = File(path).readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (line.trimLeft().startsWith('//')) continue;
        // `ratio >= 0.75` / `>= .8` — a literal fraction compared against a
        // spend ratio. 1.0 is exempt: "exceeded" is not a preference.
        if (RegExp(r'ratio\s*>=\s*0?\.\d').hasMatch(line)) {
          offenders.add('$path:${i + 1}: ${line.trim()}');
        }
      }
    }
    expect(offenders, isEmpty,
        reason: 'these warn at a hardcoded fraction instead of the budget\'s '
            'own alertThresholdPercent:\n  ${offenders.join("\n  ")}');
  });

  test('the threshold is not pushed to a server with no column for it', () {
    // `alert_threshold_percent` is device-local for V1. The server's
    // `user_budgets` has no such column, adding one needs a migration, and
    // migration 0103 is deferred by owner decision — a payload carrying an
    // unknown key is rejected outright, so shipping it would break budget sync
    // for every user rather than add a feature.
    //
    // All three push builders are covered, because a key added to any one of
    // them reaches the wire.
    const pushBuilders = <String>[
      'lib/features/planning_sync/services/planning_outbox_queue.dart',
      'lib/features/planning_sync/services/planning_push_service.dart',
      'lib/features/planning_sync/services/planning_primary_backfill_service.dart',
    ];
    final offenders = <String>[];
    for (final path in pushBuilders) {
      final lines = File(path).readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (line.trimLeft().startsWith('//')) continue;
        if (line.contains('alert_threshold_percent') ||
            line.contains('alertThresholdPercent')) {
          offenders.add('$path:${i + 1}');
        }
      }
    }
    expect(offenders, isEmpty,
        reason: 'the server has no alert_threshold_percent column. Land the '
            'server migration first, then delete this guard with the change '
            'that adds it: ${offenders.join(", ")}');
  });

  test('the pull never overwrites the local threshold', () {
    // The other half of the same decision: a pull must leave the column alone,
    // because the server cannot have an opinion about a column it does not
    // have. `_updateBudget` names every column it sets, so absence is the
    // assertion.
    final source = File(
            'lib/features/planning_sync/services/planning_pull_service.dart')
        .readAsStringSync();
    final budgetUpdate = RegExp(
      r'UPDATE budgets[\s\S]*?WHERE id',
      multiLine: true,
    ).firstMatch(source);
    expect(budgetUpdate, isNotNull, reason: 'the budgets pull update moved');
    expect(budgetUpdate!.group(0), isNot(contains('alert_threshold_percent')),
        reason: 'a pull would reset the threshold the user chose on this '
            'device to whatever the server does not know');
  });
}
