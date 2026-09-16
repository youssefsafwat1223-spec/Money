import '../entities/report_models.dart';
import 'money.dart';

/// The daily-spend arithmetic behind Home's «المصروفات اليومية» card.
///
/// Pure functions over exact [Money]; `now`/`today` are injected rather than
/// read from the clock so every result is deterministic in a test — the same
/// contract [goalPacing] follows.
///
/// Two separate jobs live here on purpose:
///   * [normalizeLastSevenDays] turns a SPARSE aggregate (days with no spend
///     are simply absent from the SQL result) into exactly seven ordered slots,
///     so the bars can never silently shift a Tuesday's value onto Wednesday.
///   * [dailyAllowance] answers "how much can I still spend today", which is
///     the one number on the card the user acts on.

/// Exactly seven [DailySpend] slots, oldest → newest, ending on [today].
///
/// Missing days become an explicit zero rather than a gap. A day whose refunds
/// exceed its spending stays NEGATIVE (see [DailySpend.isRefundDay]) — it is a
/// real state and is not clamped here.
List<DailySpend> normalizeLastSevenDays({
  required List<DailySpend> rows,
  required DateTime today,
  required String currency,
}) {
  final byDay = <DateTime, Money>{};
  for (final row in rows) {
    final key = DateTime(row.day.year, row.day.month, row.day.day);
    // The aggregate returns one row per day, but a defensive fold keeps a
    // duplicated key from dropping a value silently.
    final existing = byDay[key];
    byDay[key] = existing == null ? row.total : existing + row.total;
  }
  final start = DateTime(today.year, today.month, today.day);
  return List<DailySpend>.generate(7, (i) {
    final day = start.subtract(Duration(days: 6 - i));
    return DailySpend(day: day, total: byDay[day] ?? Money.zero(currency));
  }, growable: false);
}

/// Mean net spend across [series]. Returns zero for an empty series rather
/// than dividing by zero.
Money averageDailySpend(List<DailySpend> series, String currency) {
  if (series.isEmpty) return Money.zero(currency);
  final total = Money.sum(series.map((d) => d.total), currency);
  return total.applyRate(
    rateNumerator: BigInt.one,
    rateDenominator: BigInt.from(series.length),
  );
}

/// What is still available to spend TODAY out of the monthly budget:
/// `(limit − spent) ÷ days remaining in the month, today included`.
///
/// Returns null — never zero — when the answer is undefined:
///   * no monthly budget is set (a rate against no limit is a fiction), or
///   * the currencies do not match (this codebase never sums across currencies
///     and has no FX layer).
///
/// Returns zero when the budget is already spent or overspent: that IS the
/// answer, and it is different from "no budget".
Money? dailyAllowance({
  required Money monthlyLimit,
  required Money spentThisMonth,
  required DateTime now,
}) {
  if (monthlyLimit.isZero || monthlyLimit.isNegative) return null;
  if (monthlyLimit.currency != spentThisMonth.currency) return null;

  final remaining = monthlyLimit - spentThisMonth;
  if (remaining.isNegative || remaining.isZero) {
    return Money.zero(monthlyLimit.currency);
  }
  // Day 0 of the next month == last day of this one, so this is the count of
  // days in the current month.
  final daysInMonth = DateTime(now.year, now.month + 1, 0).day;
  final daysLeft = daysInMonth - now.day + 1; // today counts as available
  if (daysLeft <= 0) return remaining;
  return remaining.applyRate(
    rateNumerator: BigInt.one,
    rateDenominator: BigInt.from(daysLeft),
  );
}
