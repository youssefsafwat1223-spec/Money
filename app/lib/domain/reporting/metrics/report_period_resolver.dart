import '../date_range.dart';
import '../report_request.dart';

/// The concrete windows a report is computed over: the period itself and the
/// immediately-preceding equal window used for the comparison section.
class ResolvedReportPeriod {
  const ResolvedReportPeriod({
    required this.range,
    required this.previousRange,
  });

  final DateRange range;
  final DateRange previousRange;
}

/// Turns a [ReportPeriod] into concrete [DateRange]s.
///
/// - **Weekly** → the calendar week containing the reference instant. Week
///   starts **Saturday**, matching `transactionsRangeForPreset`
///   (`(weekday - DateTime.saturday) % 7`) and `RiyadhTime.startOfWeek`.
/// - **Monthly** → the calendar month; **Yearly** → the calendar year.
/// - **Custom** → its bounds verbatim.
///
/// The previous window is the equal period immediately before `range.from`.
/// Month/year use real calendar arithmetic (so a 28/29/30/31-day month is
/// compared against the true previous month, and leap years are handled by
/// `DateTime` normalisation); week/custom subtract the exact length.
///
/// All boundaries are device-local and half-open `[from, to)`; the snapshot
/// builder converts to UTC when it queries, as the Drift methods already do.
class ReportPeriodResolver {
  const ReportPeriodResolver();

  ResolvedReportPeriod resolve(ReportPeriod period, {DateTime? now}) {
    final current = now ?? DateTime.now();
    final range = _rangeFor(period, current);
    return ResolvedReportPeriod(
      range: range,
      previousRange: _previousFor(period, range),
    );
  }

  DateRange _rangeFor(ReportPeriod period, DateTime current) {
    switch (period) {
      case WeeklyPeriod():
        final today = DateTime(current.year, current.month, current.day);
        final weekStart = today.subtract(
          Duration(days: (current.weekday - DateTime.saturday) % 7),
        );
        return DateRange(weekStart, weekStart.add(const Duration(days: 7)));
      case MonthlyPeriod():
        return DateRange(
          DateTime(current.year, current.month),
          DateTime(current.year, current.month + 1),
        );
      case YearlyPeriod():
        return DateRange(
          DateTime(current.year),
          DateTime(current.year + 1),
        );
      case CustomPeriod(:final from, :final to):
        return DateRange(from, to);
    }
  }

  DateRange _previousFor(ReportPeriod period, DateRange range) {
    switch (period) {
      case MonthlyPeriod():
        // DateTime normalises month 0 → December of the previous year.
        return DateRange(
          DateTime(range.from.year, range.from.month - 1),
          range.from,
        );
      case YearlyPeriod():
        return DateRange(DateTime(range.from.year - 1), range.from);
      case WeeklyPeriod():
      case CustomPeriod():
        final length = range.length;
        return DateRange(range.from.subtract(length), range.from);
    }
  }
}
