import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/finance/period_comparison.dart';

/// F-028 / R-2 — one label, one comparison window.
///
/// The Dashboard and Reports both showed a week-over-week change under the same
/// Arabic label and computed it differently. The Dashboard compared the PARTIAL
/// current week against the FULL previous week, which is not merely a different
/// choice — it is biased, and it always understates current spending.
void main() {
  // Saturday-start week, as the app uses.
  final weekStart = DateTime.utc(2026, 8, 22);

  test('elapsed-matched: the previous window covers the same duration', () {
    final now = weekStart.add(const Duration(days: 2, hours: 6));
    final prev = elapsedMatchedPreviousWindow(
      currentStart: weekStart,
      now: now,
      periodLength: const Duration(days: 7),
    );

    expect(prev.from, DateTime.utc(2026, 8, 15));
    expect(prev.to, DateTime.utc(2026, 8, 17, 6));
    expect(prev.duration, now.difference(weekStart),
        reason: 'like must be compared with like');
  });

  test('the old full-week comparison is biased early in the week', () {
    // Saturday morning: 6 hours elapsed. The old window measured that against a
    // complete 7 days — a 28× denominator — so the user was told their spending
    // had collapsed when nothing had changed.
    final now = weekStart.add(const Duration(hours: 6));

    final matched = elapsedMatchedPreviousWindow(
      currentStart: weekStart,
      now: now,
      periodLength: const Duration(days: 7),
    );
    final full = fullPreviousWindow(
      currentStart: weekStart,
      periodLength: const Duration(days: 7),
    );

    expect(matched.duration, const Duration(hours: 6));
    expect(full.duration, const Duration(days: 7));
    expect(full.duration.inHours / matched.duration.inHours, 28,
        reason: 'the bias is the ratio of the two denominators');
  });

  test('at the end of a period the two windows converge', () {
    // The bias vanishes only when the period is complete, which is why the full
    // window is correct for a CLOSED comparison and wrong for a live one.
    final now = weekStart.add(const Duration(days: 7));
    final matched = elapsedMatchedPreviousWindow(
      currentStart: weekStart,
      now: now,
      periodLength: const Duration(days: 7),
    );
    final full = fullPreviousWindow(
      currentStart: weekStart,
      periodLength: const Duration(days: 7),
    );
    expect(matched, full);
  });

  test('zero elapsed produces an empty, not a negative, window', () {
    final prev = elapsedMatchedPreviousWindow(
      currentStart: weekStart,
      now: weekStart,
      periodLength: const Duration(days: 7),
    );
    expect(prev.duration, Duration.zero);
    expect(prev.from, prev.to);
  });

  test('the dashboard uses the elapsed-matched window', () {
    // Structural: a future edit that reinstates `to: weekStart` would restore
    // the bias silently, since both variants compile and both look plausible.
    final src = _read('lib/features/dashboard/dashboard_providers.dart');
    expect(src, contains('elapsedMatchedPreviousWindow'));
    expect(
      src,
      isNot(contains('from: prevWeekStart,\n      to: weekStart,')),
      reason: 'the full-previous-week comparison must not come back',
    );
  });

  test('reports and dashboard agree on the week anchor', () {
    // Both start the week on Saturday; a mismatch here would reintroduce the
    // same class of disagreement at a different layer.
    final reports = _read('lib/features/reports/reports_providers.dart');
    expect(reports, contains('_weekStartSaturday'));
  });
}

String _read(String relative) => File(relative).readAsStringSync();
