import '../../entities/report_models.dart';
import '../report_metrics.dart';

/// Computes headline cash-flow metrics. Pure — operates on already-collected
/// totals, never touches repositories or providers.
class ReportMetricsCalculator {
  const ReportMetricsCalculator();

  /// income / expense / net / savings-rate for one currency.
  CashFlowMetrics computeCashFlow({
    required double income,
    required double expense,
  }) {
    final net = income - expense;
    final savingsRate =
        income <= 0 ? null : ((income - expense) / income).clamp(0.0, 1.0).toDouble();
    return CashFlowMetrics(
      income: income,
      expense: expense,
      net: net,
      savingsRate: savingsRate,
    );
  }

  /// One [CurrencyCashFlow] per currency present in [totals]
  /// (`currencyTotalsBetween`), preserving input order. Currencies are never
  /// summed together — there is no FX in the app.
  List<CurrencyCashFlow> computePerCurrency(List<CurrencyTotal> totals) => [
        for (final total in totals)
          CurrencyCashFlow(
            currency: total.currency,
            metrics:
                computeCashFlow(income: total.income, expense: total.expense),
          ),
      ];
}
