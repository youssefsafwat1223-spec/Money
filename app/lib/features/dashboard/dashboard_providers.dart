import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../domain/entities/goal_entity.dart';
import '../../domain/entities/supporting_entities.dart';
import '../../domain/entities/transaction_entity.dart';
import '../common/category_catalog.dart';

class CategorySlice {
  const CategorySlice({
    required this.category,
    required this.total,
    required this.percent,
  });

  final CategoryView category;
  final double total;
  final double percent; // 0..1
}

class DashboardData {
  const DashboardData({
    required this.savedThisMonth,
    required this.streak,
    required this.topCategories,
    required this.recent,
    required this.catalog,
    this.activeGoal,
  });

  final double savedThisMonth;
  final StreakEntity streak;
  final List<CategorySlice> topCategories;
  final List<TransactionEntity> recent;
  final CategoryCatalog catalog;
  final GoalEntity? activeGoal;

  bool get isEmpty => recent.isEmpty;
}

final dashboardDataProvider = FutureProvider<DashboardData>((ref) async {
  final txRepo = ref.watch(transactionRepositoryProvider);
  final goalRepo = ref.watch(goalRepositoryProvider);
  final gamificationRepo = ref.watch(gamificationRepositoryProvider);
  final catalog = await ref.watch(categoryCatalogProvider.future);

  final now = DateTime.now();
  final monthStart = DateTime(now.year, now.month);
  final elapsed = now.difference(monthStart);
  final prevMonthStart = DateTime(now.year, now.month - 1);
  final prevSamePoint = prevMonthStart.add(elapsed);

  // «وفّرت» = مصروفات نفس الفترة من الشهر السابق − مصروفات الشهر الحالي (same-period).
  final thisMonthExpenses =
      await txRepo.expenseTotalBetween(from: monthStart, to: now);
  final prevMonthExpenses = await txRepo.expenseTotalBetween(
    from: prevMonthStart,
    to: prevSamePoint,
  );
  final saved = prevMonthExpenses - thisMonthExpenses;

  final breakdown = await txRepo.categoryBreakdown(from: monthStart, to: now);
  final totalSpend = breakdown.fold<double>(0, (sum, item) => sum + item.total);
  final topCategories = <CategorySlice>[];
  for (final item in breakdown.take(3)) {
    final view = catalog.byId(item.categoryId);
    if (view == null) continue;
    topCategories.add(
      CategorySlice(
        category: view,
        total: item.total,
        percent: totalSpend == 0 ? 0 : item.total / totalSpend,
      ),
    );
  }

  final recent = await txRepo.getRecent(limit: 5);
  final streak = await gamificationRepo.getStreak();

  final goals = await goalRepo.getAll();
  final activeGoal = goals
      .where((g) => g.status == 'active')
      .fold<GoalEntity?>(null, (best, g) {
    if (best == null) return g;
    return g.savedAmount / g.targetAmount > best.savedAmount / best.targetAmount
        ? g
        : best;
  });

  return DashboardData(
    savedThisMonth: saved,
    streak: streak,
    topCategories: topCategories,
    recent: recent,
    catalog: catalog,
    activeGoal: activeGoal,
  );
});
