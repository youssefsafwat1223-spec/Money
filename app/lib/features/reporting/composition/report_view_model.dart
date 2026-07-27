import 'report_l10n.dart';

/// Render-ready, plain-data model for one report. Everything is already
/// computed, localised, and formatted; colours are ARGB ints and chart values
/// are raw doubles. No Flutter/pdf types — so it is sendable to a render
/// isolate and the renderer never does math or lookups.
class ReportViewModel {
  const ReportViewModel({
    required this.rtl,
    required this.strings,
    required this.cover,
    required this.summary,
    required this.cashFlow,
    required this.comparison,
    required this.category,
    required this.trend,
    required this.largest,
    required this.budgets,
    required this.bills,
    required this.goals,
    required this.insights,
    required this.appendix,
    required this.periodLabel,
  });

  final bool rtl;
  final ReportStrings strings;
  final ReportCoverVM cover;
  final ReportSummaryVM summary;
  final List<CashFlowRowVM> cashFlow;
  final List<ComparisonRowVM> comparison;
  final ReportCategoryVM category;
  final ReportTrendVM trend;
  final List<AmountRowVM> largest;
  final List<BudgetBarVM> budgets;
  final List<BillRowVM> bills;
  final List<GoalBarVM> goals;
  final List<InsightRowVM> insights;
  final List<AppendixRowVM> appendix;
  final String periodLabel;
}

class AppendixRowVM {
  const AppendixRowVM({
    required this.date,
    required this.merchant,
    required this.category,
    required this.amount,
    required this.isDebit,
  });

  final String date;
  final String merchant;
  final String category;
  final String amount;
  final bool isDebit;
}

class BudgetBarVM {
  const BudgetBarVM({
    required this.label,
    required this.amounts,
    required this.ratio,
    required this.status,
    required this.colorArgb,
  });

  final String label;
  final String amounts; // "1,540 / 1,200 SAR"
  final double ratio; // clamped 0..1 for the bar
  final String status; // "28% over" / "99% of limit"
  final int colorArgb;
}

class BillRowVM {
  const BillRowVM({
    required this.name,
    required this.amount,
    required this.due,
    required this.isSubscription,
  });

  final String name;
  final String amount;
  final String due;
  final bool isSubscription;
}

class GoalBarVM {
  const GoalBarVM({
    required this.name,
    required this.amounts,
    required this.progress,
    required this.percent,
    required this.meta,
  });

  final String name;
  final String amounts; // "13,500 / 20,000 SAR"
  final double progress; // 0..1
  final String percent;
  final String meta; // "6,500 SAR to go · due 31 Dec 2026"
}

class InsightRowVM {
  const InsightRowVM(this.text, this.colorArgb);

  final String text;
  final int colorArgb;
}

class ReportCoverVM {
  const ReportCoverVM({
    required this.title,
    required this.periodLabel,
    required this.scopeLabel,
    required this.currencyLabel,
    required this.languageLabel,
    required this.generatedLabel,
  });

  final String title;
  final String periodLabel;
  final String scopeLabel;
  final String currencyLabel;
  final String languageLabel;
  final String generatedLabel;
}

class ReportSummaryVM {
  const ReportSummaryVM({required this.tiles, required this.verdict});

  final List<TileVM> tiles;
  final String verdict;
}

class TileVM {
  const TileVM(this.label, this.value, {this.colorArgb});

  final String label;
  final String value;
  final int? colorArgb;
}

class CashFlowRowVM {
  const CashFlowRowVM({
    required this.currency,
    required this.income,
    required this.expense,
    required this.net,
    required this.savingsRate,
  });

  final String currency;
  final String income;
  final String expense;
  final String net;
  final String savingsRate;
}

enum DeltaKind { up, down, neutral }

class ComparisonRowVM {
  const ComparisonRowVM({
    required this.metric,
    required this.thisValue,
    required this.previousValue,
    required this.delta,
    required this.kind,
  });

  final String metric;
  final String thisValue;
  final String previousValue;
  final String delta;
  final DeltaKind kind;
}

class ReportCategoryVM {
  const ReportCategoryVM({
    required this.slices,
    required this.rows,
    required this.centerLabel,
    required this.centerValue,
  });

  final List<DonutSliceVM> slices;
  final List<CategoryRowVM> rows;
  final String centerLabel;
  final String centerValue;
}

class DonutSliceVM {
  const DonutSliceVM(this.value, this.colorArgb);

  final double value;
  final int colorArgb;
}

class CategoryRowVM {
  const CategoryRowVM({
    required this.label,
    required this.value,
    required this.percent,
    required this.colorArgb,
  });

  final String label;
  final String value;
  final String percent;
  final int colorArgb;
}

class ReportTrendVM {
  const ReportTrendVM({
    required this.bars,
    required this.maxValue,
    required this.avg,
    required this.avgLabel,
    required this.hotIndex,
    required this.xLabels,
  });

  /// One value per day of the period (0 for days with no spend).
  final List<double> bars;
  final double maxValue;
  final double avg;
  final String avgLabel;

  /// Index of the highest bar (anomaly highlight), or -1.
  final int hotIndex;
  final List<String> xLabels;
}

class AmountRowVM {
  const AmountRowVM({
    required this.title,
    required this.subtitle,
    required this.value,
    this.colorArgb,
  });

  final String title;
  final String subtitle;
  final String value;
  final int? colorArgb;
}
