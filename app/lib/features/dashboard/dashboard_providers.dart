import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../domain/entities/budget_entity.dart';
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
    required this.spentThisMonth,
    required this.incomeThisMonth,
    required this.balance,
    required this.monthlyBudgetLimit,
    required this.monthlyBudgetRatio,
    required this.budgetPeriod,
    required this.streak,
    required this.topCategories,
    required this.recent,
    required this.catalog,
    this.activeGoal,
  });

  final double savedThisMonth;
  final double spentThisMonth;
  final double incomeThisMonth;
  final double? balance;
  final double monthlyBudgetLimit;
  final double monthlyBudgetRatio;

  /// دورة ميزانية «كل المصروفات» النشطة (null إن لم تُنشأ بعد).
  final BudgetPeriod? budgetPeriod;
  final StreakEntity streak;
  final List<CategorySlice> topCategories;
  final List<TransactionEntity> recent;
  final CategoryCatalog catalog;
  final GoalEntity? activeGoal;

  bool get isEmpty => recent.isEmpty;

  /// تسمية الفترة للعرض: «اليوم» / «الأسبوع» / «الشهر».
  String get budgetPeriodLabel => switch (budgetPeriod) {
        BudgetPeriod.daily => 'اليوم',
        BudgetPeriod.weekly => 'الأسبوع',
        BudgetPeriod.monthly => 'الشهر',
        null => 'الشهر',
      };
}

final dashboardDataProvider = FutureProvider<DashboardData>((ref) async {
  final txRepo = ref.watch(transactionRepositoryProvider);
  final goalRepo = ref.watch(goalRepositoryProvider);
  final budgetRepo = ref.watch(budgetRepositoryProvider);
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
  final thisMonthIncome =
      await txRepo.incomeTotalBetween(from: monthStart, to: now);
  final balance = await txRepo.latestBalanceAfter();
  final prevMonthExpenses = await txRepo.expenseTotalBetween(
    from: prevMonthStart,
    to: prevSamePoint,
  );
  final saved = prevMonthExpenses - thisMonthExpenses;
  // ميزانية «كل المصروفات» (الكلية) — تظهر في الـ Dashboard عند إنشائها فقط،
  // أياً كانت دورتها (يومي/أسبوعي/شهري) بحساب صرف دورتها الحالية.
  final allExpensesBudget = (await budgetRepo.getAll())
      .where((budget) => budget.isActive && budget.isAllExpenses)
      .fold<BudgetEntity?>(null, (prev, budget) => budget);
  double monthlyBudgetLimit = 0;
  double monthlyBudgetRatio = 0;
  if (allExpensesBudget != null) {
    monthlyBudgetLimit = allExpensesBudget.amount;
    final today = DateTime(now.year, now.month, now.day);
    final periodStart = switch (allExpensesBudget.period) {
      BudgetPeriod.daily => today,
      BudgetPeriod.weekly =>
        today.subtract(Duration(days: (now.weekday - DateTime.saturday) % 7)),
      BudgetPeriod.monthly => monthStart,
    };
    final spent = await txRepo.expenseTotalBetween(from: periodStart, to: now);
    monthlyBudgetRatio =
        monthlyBudgetLimit == 0 ? 0.0 : spent / monthlyBudgetLimit;
  }

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
    spentThisMonth: thisMonthExpenses,
    incomeThisMonth: thisMonthIncome,
    balance: balance,
    monthlyBudgetLimit: monthlyBudgetLimit,
    monthlyBudgetRatio: monthlyBudgetRatio,
    budgetPeriod: allExpensesBudget?.period,
    streak: streak,
    topCategories: topCategories,
    recent: recent,
    catalog: catalog,
    activeGoal: activeGoal,
  );
});
