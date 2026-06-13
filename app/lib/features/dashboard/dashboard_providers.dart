import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../domain/entities/budget_entity.dart';
import '../../domain/entities/goal_entity.dart';
import '../../domain/entities/report_models.dart';
import '../../domain/entities/supporting_entities.dart';
import '../../domain/entities/transaction_entity.dart';
import '../common/category_catalog.dart';
import '../transactions/transactions_providers.dart';

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
    required this.todaySpend,
    required this.todayIncome,
    required this.weekIncome,
    required this.balance,
    required this.monthlyBudgetLimit,
    required this.monthlyBudgetRatio,
    required this.budgetPeriod,
    required this.currency,
    required this.streak,
    required this.topCategories,
    required this.dailySpendTrend,
    required this.recent,
    required this.catalog,
    required this.pendingReview,
    required this.pendingReviewTotal,
    required this.weekSpend,
    required this.previousWeekSpend,
    required this.projectedMonthSpend,
    required this.subscriptions,
    required this.subscriptionsMonthlyTotal,
    required this.range,
    required this.currencyTotals,
    this.activeGoal,
  });

  final double savedThisMonth;
  final double spentThisMonth;
  final double incomeThisMonth;
  final double todaySpend;
  final double todayIncome;
  final double weekIncome;
  final double? balance;
  final double monthlyBudgetLimit;
  final double monthlyBudgetRatio;
  final String currency;

  /// دورة ميزانية «كل المصروفات» النشطة (null إن لم تُنشأ بعد).
  final BudgetPeriod? budgetPeriod;
  final StreakEntity streak;
  final List<CategorySlice> topCategories;
  final List<double> dailySpendTrend;
  final List<TransactionEntity> recent;
  final CategoryCatalog catalog;
  final List<TransactionEntity> pendingReview;
  final double pendingReviewTotal;
  final double weekSpend;
  final double previousWeekSpend;
  final double projectedMonthSpend;
  final List<RecurringCandidate> subscriptions;
  final double subscriptionsMonthlyTotal;
  final TransactionsDateRange range;
  final List<CurrencyTotal> currencyTotals;
  final GoalEntity? activeGoal;

  /// عرض إجماليات منفصلة لكل عملة (عند تعدّد العملات في «كل الحسابات»).
  bool get hasMultipleCurrencies => currencyTotals.length > 1;

  bool get isEmpty => recent.isEmpty;
  int get pendingReviewCount => pendingReview.length;
  int get subscriptionsCount => subscriptions.length;

  double get weekChangeRatio {
    if (previousWeekSpend == 0) return weekSpend == 0 ? 0 : 1;
    return (weekSpend - previousWeekSpend) / previousWeekSpend;
  }

  /// تسمية الفترة للعرض: «اليوم» / «الأسبوع» / «الشهر».
  String get budgetPeriodLabel => switch (budgetPeriod) {
        BudgetPeriod.daily => 'اليوم',
        BudgetPeriod.weekly => 'الأسبوع',
        BudgetPeriod.monthly => 'الشهر',
        null => 'الشهر',
      };
}

/// الحساب المختار في الـ dashboard (null = كل الحسابات).
final dashboardAccountProvider = StateProvider<String?>((ref) => null);

final dashboardDataProvider = FutureProvider<DashboardData>((ref) async {
  final txRepo = ref.watch(transactionRepositoryProvider);
  final goalRepo = ref.watch(goalRepositoryProvider);
  final budgetRepo = ref.watch(budgetRepositoryProvider);
  final gamificationRepo = ref.watch(gamificationRepositoryProvider);
  final userSettingsRepo = ref.watch(userSettingsRepositoryProvider);
  final accountRepo = ref.watch(accountRepositoryProvider);
  final catalog = await ref.watch(categoryCatalogProvider.future);
  final range = ref.watch(transactionsDateRangeProvider);
  final selectedAccountId = ref.watch(dashboardAccountProvider);
  final selectedAccount = selectedAccountId == null
      ? null
      : await accountRepo.getById(selectedAccountId);
  // الحساب المختار غير موجود (حُذف) → ارجع لكل الحسابات.
  final accountId = selectedAccount?.id;

  final now = DateTime.now();
  final rangeStart =
      DateTime(range.from.year, range.from.month, range.from.day);
  final rangeEnd = range.to.isAfter(now) ? now : range.to;
  final daysInRange =
      rangeEnd.difference(rangeStart).inDays.abs().clamp(1, 3660) + 1;
  final previousStart = rangeStart.subtract(Duration(days: daysInRange));
  final previousEnd = rangeStart.subtract(const Duration(seconds: 1));
  final today = DateTime(now.year, now.month, now.day);
  final weekStart =
      today.subtract(Duration(days: (now.weekday - DateTime.saturday) % 7));
  final prevWeekStart = weekStart.subtract(const Duration(days: 7));

  // «وفّرت» = مصروفات الفترة السابقة بنفس طول الفترة المختارة − الفترة الحالية.
  final thisMonthExpenses = await txRepo.expenseTotalBetween(
      from: rangeStart, to: rangeEnd, accountId: accountId);
  final thisMonthIncome = await txRepo.incomeTotalBetween(
      from: rangeStart, to: rangeEnd, accountId: accountId);
  final balance = await txRepo.latestBalanceAfter(accountId: accountId);
  final prevMonthExpenses = await txRepo.expenseTotalBetween(
    from: previousStart,
    to: previousEnd,
    accountId: accountId,
  );
  final weekSpend = await txRepo.expenseTotalBetween(
      from: weekStart, to: now, accountId: accountId);
  final todaySpend = await txRepo.expenseTotalBetween(
      from: today, to: now, accountId: accountId);
  final todayIncome = await txRepo.incomeTotalBetween(
      from: today, to: now, accountId: accountId);
  final weekIncome = await txRepo.incomeTotalBetween(
      from: weekStart, to: now, accountId: accountId);
  final previousWeekSpend = await txRepo.expenseTotalBetween(
    from: prevWeekStart,
    to: weekStart,
    accountId: accountId,
  );
  final allTransactions = await txRepo.getAll();
  final pendingReview = allTransactions
      .where((tx) => tx.status == TransactionStatus.pending)
      .take(3)
      .toList(growable: false);
  final pendingReviewTotal =
      pendingReview.fold<double>(0, (sum, tx) => sum + tx.amount);
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
    final periodStart = switch (allExpensesBudget.period) {
      BudgetPeriod.daily => today,
      BudgetPeriod.weekly =>
        today.subtract(Duration(days: (now.weekday - DateTime.saturday) % 7)),
      BudgetPeriod.monthly => rangeStart,
    };
    final spent = await txRepo.expenseTotalBetween(
        from: periodStart, to: now, accountId: accountId);
    monthlyBudgetRatio =
        monthlyBudgetLimit == 0 ? 0.0 : spent / monthlyBudgetLimit;
  }

  final breakdown = await txRepo.categoryBreakdown(
      from: rangeStart, to: rangeEnd, accountId: accountId);
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
  final dailySpendTrend = (await txRepo.dailyExpenseTotals(
          from: rangeStart, to: rangeEnd, accountId: accountId))
      .map((day) => day.total)
      .toList(growable: false);

  final recent = await txRepo.getRecent(limit: 5, accountId: accountId);
  // إجماليات منفصلة لكل عملة — فقط في وضع «كل الحسابات».
  final currencyTotals = accountId == null
      ? await txRepo.currencyTotalsBetween(from: rangeStart, to: rangeEnd)
      : const <CurrencyTotal>[];
  final streak = await gamificationRepo.getStreak();
  final settings = await userSettingsRepo.getSettings();
  final subscriptions =
      (await txRepo.recurringCandidates()).take(3).toList(growable: false);
  final subscriptionsMonthlyTotal = subscriptions.fold<double>(
    0,
    (sum, item) => sum + item.averageAmount,
  );
  final projectedMonthSpend = daysInRange == 0
      ? thisMonthExpenses
      : (thisMonthExpenses / daysInRange) * 30;

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
    todaySpend: todaySpend,
    todayIncome: todayIncome,
    weekIncome: weekIncome,
    balance: balance,
    monthlyBudgetLimit: monthlyBudgetLimit,
    monthlyBudgetRatio: monthlyBudgetRatio,
    budgetPeriod: allExpensesBudget?.period,
    currency: selectedAccount?.currency ?? settings.currency,
    streak: streak,
    topCategories: topCategories,
    dailySpendTrend: dailySpendTrend,
    recent: recent,
    catalog: catalog,
    pendingReview: pendingReview,
    pendingReviewTotal: pendingReviewTotal,
    weekSpend: weekSpend,
    previousWeekSpend: previousWeekSpend,
    projectedMonthSpend: projectedMonthSpend,
    subscriptions: subscriptions,
    subscriptionsMonthlyTotal: subscriptionsMonthlyTotal,
    range: range,
    currencyTotals: currencyTotals,
    activeGoal: activeGoal,
  );
});
