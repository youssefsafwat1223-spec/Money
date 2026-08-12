// Pure result models for report calculations. No Flutter / Riverpod / pdf.

import '../finance/money.dart';

/// Headline cash-flow metrics for a single currency over one period.
///
/// Refund handling (product decision): refunds are treated as negative expense
/// at the category level and are excluded from income — so `income` here is the
/// confirmed `type = 'income'` total (refunds excluded, matching the SQL income
/// total) and `expense` is the report's expense figure for the period.
class CashFlowMetrics {
  const CashFlowMetrics({
    required this.income,
    required this.expense,
    required this.net,
    required this.savingsRate,
  });

  final Money income;
  final Money expense;

  /// `income - expense`.
  final Money net;

  /// `(income - expense) / income`, clamped to `0..1` to match the app's
  /// `savingsScore`. `null` when income is `<= 0` (undefined, shown as "—"
  /// rather than a magic number).
  final double? savingsRate;
}

/// Cash-flow metrics tagged with their currency (multi-currency is never summed).
class CurrencyCashFlow {
  const CurrencyCashFlow({required this.currency, required this.metrics});

  final String currency;
  final CashFlowMetrics metrics;
}

/// A change in a single metric between the current period and the previous
/// equal-length period.
class MetricDelta {
  const MetricDelta({
    required this.current,
    required this.previous,
    required this.absolute,
    required this.percent,
  });

  final Money current;
  final Money previous;

  /// `current - previous`.
  final Money absolute;

  /// `(current - previous) / previous`; `null` when `previous == 0`
  /// (percentage change is undefined), matching `ReportSection.deltaPercent`.
  final double? percent;

  bool get isIncrease => absolute.compareTo(Money.zero(absolute.currency)) > 0;
  bool get isDecrease => absolute.compareTo(Money.zero(absolute.currency)) < 0;
}

/// Previous-period comparison for the headline metrics.
class ComparisonMetrics {
  const ComparisonMetrics({
    required this.income,
    required this.expense,
    required this.net,
    required this.savingsRatePoints,
  });

  final MetricDelta income;
  final MetricDelta expense;
  final MetricDelta net;

  /// Change in savings rate in **percentage points** (`current - previous`).
  /// `null` when either period's savings rate is undefined (income `<= 0`).
  final double? savingsRatePoints;
}
