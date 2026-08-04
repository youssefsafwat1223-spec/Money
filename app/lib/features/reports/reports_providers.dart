import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../domain/entities/report_models.dart';
import '../common/category_catalog.dart';
import '../dashboard/dashboard_providers.dart' show CategorySlice;
import '../transactions/transactions_providers.dart';

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

  /// أفضل يوم توفيرًا = اليوم الوحيد بأقل إنفاق غير صفري.
  DailySpend? get bestSavingsDay {
    final active = dailySpend.where((d) => d.total > 0).toList();
    if (active.isEmpty) return null;
    return active.reduce((a, b) => a.total < b.total ? a : b);
  }

  /// أكبر فئة إنفاق.
  CategorySlice? get topCategory =>
      topCategories.isEmpty ? null : topCategories.first;

  /// أكبر متجر إنفاقًا.
  MerchantSpend? get topMerchant =>
      topMerchants.isEmpty ? null : topMerchants.first;
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
  ref.watch(dbRevisionProvider);
  final txRepo = ref.watch(transactionRepositoryProvider);
  final accountRepo = ref.watch(accountRepositoryProvider);
  final catalog = await ref.watch(categoryCatalogProvider.future);
  final selectedAccountId = ref.watch(activeAccountIdProvider);
  final selectedAccount = selectedAccountId == null
      ? null
      : await accountRepo.getById(selectedAccountId);
  final defaultAccount = await accountRepo.getDefault();
  final accountId = (selectedAccount ?? defaultAccount)?.id;
  final now = DateTime.now();
  final range =
      effectiveTransactionsRange(ref.watch(transactionsDateRangeProvider));
  final rangeEnd = range.to.isAfter(now) ? now : range.to;

  Future<ReportSection> section(
      DateTime from, DateTime to, DateTime prevFrom, DateTime prevTo) async {
    // MALI-063n: always the canonical Drift aggregates (the dormant Supabase
    // summary path is retired).
    final total = await txRepo.expenseTotalBetween(
        from: from, to: to, accountId: accountId);
    final prevTotal = await txRepo.expenseTotalBetween(
        from: prevFrom, to: prevTo, accountId: accountId);
    final breakdown = await txRepo.categoryBreakdown(
        from: from, to: to, accountId: accountId);
    final sumAll = breakdown.fold<double>(0, (s, i) => s + i.total);
    final topCategories = <CategorySlice>[];
    for (final item in breakdown.take(18)) {
      final view =
          catalog.byId(item.categoryId) ?? catalog.byKey(item.categoryId);
      if (view == null) continue;
      topCategories.add(CategorySlice(
        category: view,
        total: item.total,
        percent: sumAll == 0 ? 0 : item.total / sumAll,
        count: item.count,
      ));
    }
    final topMerchants = await txRepo.merchantBreakdown(
        from: from, to: to, limit: 8, accountId: accountId);
    final dailySpend = await txRepo.dailyExpenseTotals(
        from: from, to: to, accountId: accountId);
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
  final weekly = await section(
      weekStart, now, prevWeekStart, prevWeekStart.add(weekElapsed));

  // الفترة المختارة — مقارنة بنفس طول الفترة السابقة.
  final rangeStart =
      DateTime(range.from.year, range.from.month, range.from.day);
  final daysInRange =
      rangeEnd.difference(rangeStart).inDays.abs().clamp(1, 3660) + 1;
  final prevRangeStart = rangeStart.subtract(Duration(days: daysInRange));
  // MALI-028: the previous period ends where the current one begins — a genuine
  // exclusive boundary, not an epsilon-adjusted last instant.
  final prevRangeEnd = rangeStart;
  final monthly =
      await section(rangeStart, rangeEnd, prevRangeStart, prevRangeEnd);

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
