// Deterministic, rule-based report insights. Pure Dart — no AI, no Flutter.
// The engine emits structured [Insight]s (a code + severity + numeric args);
// the composer localises them into sentences.

enum InsightSeverity { danger, warning, success, info }

enum InsightCode {
  spendingDecreased,
  spendingIncreased,
  savingsImproved,
  savingsDeclined,
  budgetsOver,
  dominantCategory,
  billDueSoon,
  unusualDay,
}

class Insight {
  const Insight(this.code, this.severity, [this.args = const <String, Object?>{}]);

  final InsightCode code;
  final InsightSeverity severity;
  final Map<String, Object?> args;
}

/// Plain-data inputs the rules evaluate (already computed by the composer).
class InsightInput {
  const InsightInput({
    this.expenseDeltaPct,
    this.savingsPointsDelta,
    this.overBudgetCount = 0,
    this.dominantCategoryLabel,
    this.dominantCategoryShare = 0,
    this.dueBillName,
    this.dueBillAmount,
    this.dueBillCurrency,
    this.dueBillInDays,
    this.hasUnusualDay = false,
    this.unusualDayAmount = 0,
    this.unusualDayFactor = 0,
    this.currency,
  });

  /// Expense change vs previous period, as a fraction (null if previous == 0).
  final double? expenseDeltaPct;

  /// Savings-rate change in percentage points, as a fraction (null if undefined).
  final double? savingsPointsDelta;
  final int overBudgetCount;
  final String? dominantCategoryLabel;
  final double dominantCategoryShare;
  final String? dueBillName;
  final double? dueBillAmount;
  final String? dueBillCurrency;
  final int? dueBillInDays;
  final bool hasUnusualDay;
  final double unusualDayAmount;
  final double unusualDayFactor;
  final String? currency;
}

/// Evaluates the rules and returns insights ranked most-severe first, capped.
class InsightEngine {
  const InsightEngine();

  static const double _spendingThreshold = 0.10; // 10%
  static const double _savingsThreshold = 0.05; // 5 pp
  static const double _dominantThreshold = 0.40; // 40% of spend
  static const int _dueSoonDays = 14;
  static const int _maxInsights = 8;

  List<Insight> evaluate(InsightInput input) {
    final insights = <Insight>[];

    final expenseDelta = input.expenseDeltaPct;
    if (expenseDelta != null && expenseDelta.abs() >= _spendingThreshold) {
      insights.add(expenseDelta < 0
          ? Insight(InsightCode.spendingDecreased, InsightSeverity.success,
              <String, Object?>{'pct': expenseDelta.abs()})
          : Insight(InsightCode.spendingIncreased, InsightSeverity.warning,
              <String, Object?>{'pct': expenseDelta.abs()}));
    }

    final savings = input.savingsPointsDelta;
    if (savings != null && savings.abs() >= _savingsThreshold) {
      insights.add(savings > 0
          ? Insight(InsightCode.savingsImproved, InsightSeverity.success,
              <String, Object?>{'pp': savings})
          : Insight(InsightCode.savingsDeclined, InsightSeverity.warning,
              <String, Object?>{'pp': savings.abs()}));
    }

    if (input.overBudgetCount > 0) {
      insights.add(Insight(InsightCode.budgetsOver, InsightSeverity.danger,
          <String, Object?>{'count': input.overBudgetCount}));
    }

    if (input.dominantCategoryLabel != null &&
        input.dominantCategoryShare >= _dominantThreshold) {
      insights.add(Insight(
        InsightCode.dominantCategory,
        InsightSeverity.info,
        <String, Object?>{
          'category': input.dominantCategoryLabel,
          'share': input.dominantCategoryShare,
        },
      ));
    }

    if (input.dueBillName != null &&
        (input.dueBillInDays ?? 1 << 30) <= _dueSoonDays) {
      insights.add(Insight(
        InsightCode.billDueSoon,
        InsightSeverity.warning,
        <String, Object?>{
          'bill': input.dueBillName,
          'amount': input.dueBillAmount,
          'currency': input.dueBillCurrency,
          'days': input.dueBillInDays,
        },
      ));
    }

    if (input.hasUnusualDay) {
      insights.add(Insight(
        InsightCode.unusualDay,
        InsightSeverity.info,
        <String, Object?>{
          'amount': input.unusualDayAmount,
          'factor': input.unusualDayFactor,
          'currency': input.currency,
        },
      ));
    }

    insights.sort((a, b) => a.severity.index.compareTo(b.severity.index));
    return insights.take(_maxInsights).toList();
  }
}
