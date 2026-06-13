import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../domain/entities/report_models.dart';
import '../common/category_catalog.dart';
import '../dashboard/dashboard_providers.dart' show CategorySlice;

class ReportSection {
  const ReportSection({
    required this.total,
    required this.prevTotal,
    required this.topCategories,
    required this.topMerchants,
    required this.dailySpend,
    required this.anomaly,
  });

  final double total;
  final double prevTotal;
  final List<CategorySlice> topCategories;
  final List<MerchantSpend> topMerchants;
  final List<DailySpend> dailySpend;
  final SpendingAnomaly? anomaly;

  /// نسبة التغيّر مقابل الفترة السابقة (null إذا لا توجد فترة سابقة).
  double? get deltaPercent =>
      prevTotal == 0 ? null : (total - prevTotal) / prevTotal;

  double get averageDaily {
    if (dailySpend.isEmpty) return 0;
    return dailySpend.fold<double>(0, (sum, day) => sum + day.total) /
        dailySpend.length;
  }

  double get highestDaily {
    if (dailySpend.isEmpty) return 0;
    return dailySpend.map((day) => day.total).reduce((a, b) => a > b ? a : b);
  }
}

class SpendingAnomaly {
  const SpendingAnomaly({
    required this.day,
    required this.total,
    required this.baseline,
    required this.ratio,
  });

  final DateTime day;
  final double total;
  final double baseline;
  final double ratio;
}

class ReportsBundle {
  const ReportsBundle({required this.weekly, required this.monthly});

  final ReportSection weekly;
  final ReportSection monthly;
}

DateTime _weekStartSaturday(DateTime now) {
  final daysSinceSat = (now.weekday - DateTime.saturday) % 7;
  return DateTime(now.year, now.month, now.day)
      .subtract(Duration(days: daysSinceSat));
}

final reportsProvider = FutureProvider<ReportsBundle>((ref) async {
  final txRepo = ref.watch(transactionRepositoryProvider);
  final catalog = await ref.watch(categoryCatalogProvider.future);
  final now = DateTime.now();

  Future<ReportSection> section(
      DateTime from, DateTime prevFrom, DateTime prevTo) async {
    final total = await txRepo.expenseTotalBetween(from: from, to: now);
    final prevTotal =
        await txRepo.expenseTotalBetween(from: prevFrom, to: prevTo);
    final breakdown = await txRepo.categoryBreakdown(from: from, to: now);
    final sumAll = breakdown.fold<double>(0, (s, i) => s + i.total);
    final topCategories = <CategorySlice>[];
    for (final item in breakdown.take(3)) {
      final view = catalog.byId(item.categoryId);
      if (view == null) continue;
      topCategories.add(CategorySlice(
        category: view,
        total: item.total,
        percent: sumAll == 0 ? 0 : item.total / sumAll,
      ));
    }
    final topMerchants =
        await txRepo.merchantBreakdown(from: from, to: now, limit: 3);
    final dailySpend = await txRepo.dailyExpenseTotals(from: from, to: now);
    return ReportSection(
      total: total,
      prevTotal: prevTotal,
      topCategories: topCategories,
      topMerchants: topMerchants,
      dailySpend: dailySpend,
      anomaly: detectSpendingAnomaly(dailySpend),
    );
  }

  // أسبوعي (يبدأ السبت) — مقارنة بنفس المدى من الأسبوع السابق.
  final weekStart = _weekStartSaturday(now);
  final weekElapsed = now.difference(weekStart);
  final prevWeekStart = weekStart.subtract(const Duration(days: 7));
  final weekly =
      await section(weekStart, prevWeekStart, prevWeekStart.add(weekElapsed));

  // شهري — مقارنة بنفس المدى من الشهر السابق.
  final monthStart = DateTime(now.year, now.month);
  final monthElapsed = now.difference(monthStart);
  final prevMonthStart = DateTime(now.year, now.month - 1);
  final monthly = await section(
      monthStart, prevMonthStart, prevMonthStart.add(monthElapsed));

  return ReportsBundle(weekly: weekly, monthly: monthly);
});

SpendingAnomaly? detectSpendingAnomaly(List<DailySpend> dailySpend) {
  final activeDays =
      dailySpend.where((day) => day.total > 0).toList(growable: false);
  if (activeDays.length < 4) return null;

  final candidate = activeDays.reduce(
    (a, b) => a.total >= b.total ? a : b,
  );
  final baselineDays =
      activeDays.where((day) => !_isSameDate(day.day, candidate.day));
  final baselineTotal =
      baselineDays.fold<double>(0, (sum, day) => sum + day.total);
  final baselineCount = activeDays.length - 1;
  if (baselineCount <= 0) return null;

  final baseline = baselineTotal / baselineCount;
  if (baseline <= 0) return null;

  final ratio = candidate.total / baseline;
  final difference = candidate.total - baseline;
  if (ratio < 1.8 || difference < 75) return null;

  return SpendingAnomaly(
    day: candidate.day,
    total: candidate.total,
    baseline: baseline,
    ratio: ratio,
  );
}

bool _isSameDate(DateTime a, DateTime b) {
  return a.year == b.year && a.month == b.month && a.day == b.day;
}
