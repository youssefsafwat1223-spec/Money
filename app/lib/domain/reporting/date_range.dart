/// A half-open time window `[from, to)`.
///
/// Boundaries are **device-local** `DateTime`s: calendar boundaries follow the
/// local timezone, matching [RiyadhTime] (`lib/core/utils/riyadh_time.dart`) and
/// the transactions date presets (`transactionsRangeForPreset`). Callers convert
/// to UTC with `.toUtc()` when querying the repositories, exactly as the Drift
/// aggregation methods already do (e.g. `expenseTotalBetween` binds
/// `from.toUtc()` / `to.toUtc()`).
class DateRange {
  const DateRange(this.from, this.to);

  final DateTime from;
  final DateTime to;

  /// Length of the window. For calendar periods this reflects the real number
  /// of days (28–31 for months, 365/366 for years).
  Duration get length => to.difference(from);

  /// Whether [moment] falls in `[from, to)` (inclusive start, exclusive end).
  bool contains(DateTime moment) =>
      !moment.isBefore(from) && moment.isBefore(to);

  @override
  bool operator ==(Object other) =>
      other is DateRange && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(from, to);

  @override
  String toString() => 'DateRange($from → $to)';
}
