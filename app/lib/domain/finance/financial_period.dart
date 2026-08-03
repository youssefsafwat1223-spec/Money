import '../../core/utils/riyadh_time.dart';
import '../reporting/date_range.dart';

/// MALI-062n / 028 / 063n — the ONE canonical financial period contract.
///
/// Every financial window is a **half-open** interval `[from, to)`: a moment at
/// exactly `to` belongs to the NEXT period, never this one. Boundaries are
/// computed in the **business timezone**, which is the device-local zone
/// (`RiyadhTime`); a period is derived once, here, and reused by every surface
/// (dashboard, reports, budgets, comparisons, notifications) so they cannot
/// disagree. The week starts on **Saturday** (see [RiyadhTime.startOfWeek]).
///
/// Surfaces must obtain periods from this resolver rather than re-deriving day/
/// week/month boundaries with ad-hoc `DateTime` math.
enum FinancialPeriodKind { day, week, month, year }

class FinancialPeriod {
  const FinancialPeriod._();

  static DateRange day(DateTime moment) =>
      DateRange(RiyadhTime.startOfDay(moment), RiyadhTime.endOfDay(moment));

  /// Saturday-anchored week, half-open `[startOfWeek, +7 days)`.
  static DateRange week(DateTime moment) =>
      DateRange(RiyadhTime.startOfWeek(moment), RiyadhTime.endOfWeek(moment));

  static DateRange month(DateTime moment) =>
      DateRange(RiyadhTime.startOfMonth(moment), RiyadhTime.endOfMonth(moment));

  static DateRange year(DateTime moment) {
    final local = moment.toLocal();
    return DateRange(DateTime(local.year), DateTime(local.year + 1));
  }

  static DateRange of(FinancialPeriodKind kind, DateTime moment) =>
      switch (kind) {
        FinancialPeriodKind.day => day(moment),
        FinancialPeriodKind.week => week(moment),
        FinancialPeriodKind.month => month(moment),
        FinancialPeriodKind.year => year(moment),
      };

  /// A custom range. [toExclusive] is the half-open upper bound — pass the moment
  /// AFTER the last included instant (e.g. the day after the last day).
  static DateRange custom(DateTime from, DateTime toExclusive) =>
      DateRange(from, toExclusive);
}
