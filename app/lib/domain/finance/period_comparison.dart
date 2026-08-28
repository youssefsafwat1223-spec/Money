/// R-2 / F-028 — canonical period-comparison windows.
///
/// ## The defect this replaces
/// Two surfaces showed a week-over-week change under the same Arabic label
/// («عن الأسبوع الماضي» / «مقارنة بالأسبوع الماضي») and computed it differently:
///
/// * **Reports** compared `weekStart → now` against
///   `prevWeekStart → prevWeekStart + elapsed` — an ELAPSED-MATCHED window.
/// * **Dashboard** compared `weekStart → now` (partial) against
///   `prevWeekStart → weekStart` — a FULL seven days.
///
/// The dashboard comparison is not merely different, it is **biased**: on a
/// Saturday morning it weighs a few hours against a complete week and reports a
/// near-total collapse in spending. The user is told they are spending far less
/// when nothing has changed.
///
/// ## The rule
/// Compare like with like: the previous window covers the same ELAPSED duration
/// as the current one, anchored to the previous period's start.
///
/// A full-period comparison is legitimate for a *closed* period (last month vs
/// the month before), which is why [fullPreviousWindow] exists and is named for
/// what it does. It must never be used against a period still in progress.
library;

/// A half-open `[from, to)` instant range.
class DateWindow {
  const DateWindow(this.from, this.to);

  final DateTime from;
  final DateTime to;

  Duration get duration => to.difference(from);

  @override
  String toString() => 'DateWindow(${from.toIso8601String()} → '
      '${to.toIso8601String()})';

  @override
  bool operator ==(Object other) =>
      other is DateWindow && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(from, to);
}

/// The previous window matching the ELAPSED portion of the current one.
///
/// Use this whenever the current period is still in progress — which is every
/// "this week so far" and "this month so far" comparison in the app.
DateWindow elapsedMatchedPreviousWindow({
  required DateTime currentStart,
  required DateTime now,
  required Duration periodLength,
}) {
  final elapsed = now.difference(currentStart);
  final previousStart = currentStart.subtract(periodLength);
  return DateWindow(previousStart, previousStart.add(elapsed));
}

/// The complete previous period.
///
/// Only correct for a CLOSED comparison (a finished month against the one
/// before it). Using it against an in-progress period produces the F-028 bias.
DateWindow fullPreviousWindow({
  required DateTime currentStart,
  required Duration periodLength,
}) =>
    DateWindow(currentStart.subtract(periodLength), currentStart);
