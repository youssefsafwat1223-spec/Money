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
  });

  final double total;
  final double prevTotal;
  final List<CategorySlice> topCategories;
  final List<MerchantSpend> topMerchants;

  /// نسبة التغيّر مقابل الفترة السابقة (null إذا لا توجد فترة سابقة).
  double? get deltaPercent =>
      prevTotal == 0 ? null : (total - prevTotal) / prevTotal;
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

  Future<ReportSection> section(DateTime from, DateTime prevFrom, DateTime prevTo) async {
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
    return ReportSection(
      total: total,
      prevTotal: prevTotal,
      topCategories: topCategories,
      topMerchants: topMerchants,
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
