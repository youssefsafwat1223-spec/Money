import '../report_metrics.dart';
import '../../finance/money.dart';

/// Computes previous-period comparisons. Pure.
class ComparisonCalculator {
  const ComparisonCalculator();

  /// Absolute and percentage change from [previous] to [current]. Percentage is
  /// `null` when `previous == 0` (undefined), matching `ReportSection.deltaPercent`.
  MetricDelta delta(Money current, Money previous) {
    final absolute = current - previous;
    return MetricDelta(
      current: current,
      previous: previous,
      absolute: absolute,
      percent:
          previous.isZero ? null : absolute.toDouble() / previous.toDouble(),
    );
  }

  /// Full comparison for the headline metrics. Savings rate is compared in
  /// percentage points and is `null` if either side is undefined.
  ComparisonMetrics compare(CashFlowMetrics current, CashFlowMetrics previous) {
    final currentRate = current.savingsRate;
    final previousRate = previous.savingsRate;
    return ComparisonMetrics(
      income: delta(current.income, previous.income),
      expense: delta(current.expense, previous.expense),
      net: delta(current.net, previous.net),
      savingsRatePoints: (currentRate == null || previousRate == null)
          ? null
          : currentRate - previousRate,
    );
  }
}
