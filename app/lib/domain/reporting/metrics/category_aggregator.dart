import '../../entities/category_spend.dart';

/// One row of the spending-by-category section.
class CategoryReportSlice {
  const CategoryReportSlice({
    required this.categoryId,
    required this.label,
    required this.total,
    required this.percent,
    required this.count,
    this.isOther = false,
  });

  /// `null` for the aggregated "Other" remainder row.
  final String? categoryId;
  final String label;
  final double total;

  /// Fraction `0..1` of the period's total expense.
  final double percent;
  final int count;

  /// True for the synthetic remainder row (uncategorised + deleted-category
  /// spend) that makes the shares sum to 100%.
  final bool isOther;
}

/// Turns the repo `categoryBreakdown` into ranked slices whose shares sum to
/// ~1.0. Pure.
class CategoryAggregator {
  const CategoryAggregator();

  /// Builds ranked slices from [breakdown] (categorised expense only, from
  /// `categoryBreakdown`).
  ///
  /// [labelFor] resolves a `categoryId` to a display label, or returns `null`
  /// for a **deleted / unknown** category. [totalExpense] is the true period
  /// expense (`expenseTotalBetween`) used as the denominator, so both
  /// uncategorised spend and deleted-category spend are captured by an explicit
  /// "Other" remainder ([otherLabel]) instead of silently dropping — fixing the
  /// "percentages sum to <100%" behaviour of the current screen.
  List<CategoryReportSlice> aggregate({
    required List<CategorySpend> breakdown,
    required String? Function(String categoryId) labelFor,
    required double totalExpense,
    required String otherLabel,
  }) {
    final slices = <CategoryReportSlice>[];
    var resolvedTotal = 0.0;
    for (final item in breakdown) {
      final label = labelFor(item.categoryId);
      if (label == null) continue; // deleted/unknown → folds into "Other" below
      resolvedTotal += item.total;
      slices.add(
        CategoryReportSlice(
          categoryId: item.categoryId,
          label: label,
          total: item.total,
          percent: totalExpense <= 0 ? 0.0 : item.total / totalExpense,
          count: item.count,
        ),
      );
    }
    slices.sort((a, b) => b.total.compareTo(a.total));

    final remainder = totalExpense - resolvedTotal;
    if (remainder > 0.005) {
      slices.add(
        CategoryReportSlice(
          categoryId: null,
          label: otherLabel,
          total: remainder,
          percent: totalExpense <= 0 ? 0.0 : remainder / totalExpense,
          count: 0,
          isOther: true,
        ),
      );
    }
    return slices;
  }
}
