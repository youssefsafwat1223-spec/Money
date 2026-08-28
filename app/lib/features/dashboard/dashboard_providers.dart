import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../domain/entities/account_entity.dart';
import '../../domain/entities/budget_entity.dart';
import '../../domain/entities/goal_entity.dart';
import '../../domain/entities/report_models.dart';
import '../../domain/entities/supporting_entities.dart';
import '../../domain/entities/transaction_entity.dart';
import '../../domain/finance/budget_period.dart';
import '../../domain/finance/money.dart';
import '../../domain/repositories/transaction_repository.dart';
import '../common/category_catalog.dart';
import '../transactions/transactions_providers.dart';

/// ملخص تقدّم ميزانية واحدة (كل الميزانيات الفعّالة)، تُعرض في قسم
/// "كل الميزانيات" على الداشبورد.
class DashboardBudgetEntry {
  const DashboardBudgetEntry({
    required this.budgetId,
    required this.label,
    required this.spent,
    required this.limit,
    required this.ratio,
    required this.period,
    this.accountId,
    this.accountName,
  });

  final String budgetId;
  final String label;
  final Money spent;
  final Money limit;
  final double ratio;
  final BudgetPeriod period;
  final String? accountId;
  final String? accountName;
}

class CategorySlice {
  const CategorySlice({
    required this.category,
    required this.total,
    required this.percent,
    this.count = 0,
  });

  final CategoryView category;
  final Money total;
  final double percent; // 0..1
  final int count;
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
    required this.dailyBudgetLimit,
    required this.weeklyBudgetLimit,
    required this.monthlyBudgetLimit,
    required this.monthlyBudgetRatio,
    required this.budgetPeriod,
    required this.currency,
    required this.streak,
    required this.topCategories,
    required this.dailySpendTrend,
    required this.weeklyDailySpend,
    required this.topMerchants,
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
    required this.budgetProgress,
    required this.rangeExpense,
    required this.rangeIncome,
    this.activeGoal,
  });

  final Money savedThisMonth;
  final Money spentThisMonth;
  final Money incomeThisMonth;
  final Money todaySpend;
  final Money todayIncome;
  final Money weekIncome;
  final Money? balance;
  final Money dailyBudgetLimit;
  final Money weeklyBudgetLimit;
  final Money monthlyBudgetLimit;
  final double monthlyBudgetRatio;
  final String currency;

  /// Legacy label kept for older widgets; monthly is the main dashboard ring.
  final BudgetPeriod? budgetPeriod;
  final StreakEntity streak;
  final List<CategorySlice> topCategories;
  final List<double> dailySpendTrend;
  final List<DailySpend> weeklyDailySpend;
  final List<MerchantSpend> topMerchants;
  final List<TransactionEntity> recent;
  final CategoryCatalog catalog;
  final List<TransactionEntity> pendingReview;
  final Money pendingReviewTotal;
  final Money weekSpend;
  final Money previousWeekSpend;
  final double projectedMonthSpend;
  final List<RecurringCandidate> subscriptions;
  final Money subscriptionsMonthlyTotal;
  final TransactionsDateRange range;
  final List<CurrencyTotal> currencyTotals;
  final List<DashboardBudgetEntry> budgetProgress;
  final GoalEntity? activeGoal;

  /// Expense/income totals for the currently selected filter [range] — not
  /// tied to the calendar month, unlike [spentThisMonth]/[incomeThisMonth].
  /// Feeds the dashboard's income-vs-expense summary card.
  final Money rangeExpense;
  final Money rangeIncome;

  /// عرض إجماليات منفصلة لكل عملة (عند تعدّد العملات في «كل الحسابات»).
  bool get hasMultipleCurrencies => currencyTotals.length > 1;

  bool get isEmpty => recent.isEmpty;
  int get pendingReviewCount => pendingReview.length;
  int get subscriptionsCount => subscriptions.length;

  double get weekChangeRatio {
    if (previousWeekSpend.isZero) return weekSpend.isZero ? 0 : 1;
    return (weekSpend - previousWeekSpend).toDouble() /
        previousWeekSpend.toDouble();
  }

  // ─── درجة قرش ───────────────────────────────────────────────────────────────

  /// التزام بالميزانية: 0-100. إذا لم تُحدَّد ميزانية → 75 (محايد).
  double get budgetScore {
    if (monthlyBudgetLimit.isZero || monthlyBudgetLimit.isNegative) return 75;
    return ((1 - monthlyBudgetRatio).clamp(0.0, 1.0) * 100);
  }

  /// معدل الادخار: 0-100. إذا لم يوجد دخل → 50 (محايد).
  double get savingsScore {
    if (incomeThisMonth.isZero || incomeThisMonth.isNegative) return 50;
    return (((incomeThisMonth - spentThisMonth).toDouble() /
                incomeThisMonth.toDouble())
            .clamp(0.0, 1.0) *
        100);
  }

  /// انتظام التسجيل (streak): 0-100. 30 أسبوعًا = 100%.
  double get streakScore => (streak.currentStreak / 30).clamp(0.0, 1.0) * 100;

  /// تنوع الإنفاق بناءً على عدد الفئات: 0-100. 5 فئات أو أكثر = 100%.
  double get diversityScore => (topCategories.length / 5).clamp(0.0, 1.0) * 100;

  /// درجة قرش الإجمالية (0-100) — وزن مرجّح من المكونات الأربعة.
  int get qirshScore => (budgetScore * 0.35 +
          savingsScore * 0.30 +
          streakScore * 0.20 +
          diversityScore * 0.15)
      .round()
      .clamp(0, 100);

  /// تسمية الفترة للعرض: «اليوم» / «الأسبوع» / «الشهر».
  String get budgetPeriodLabel => switch (budgetPeriod) {
        BudgetPeriod.daily => 'اليوم',
        BudgetPeriod.weekly => 'الأسبوع',
        BudgetPeriod.monthly => 'الشهر',
        BudgetPeriod.yearly => 'السنة',
        null => 'الشهر',
      };
}

/// الحساب المختار في الـ dashboard (null = الحساب الافتراضي الحالي).
final dashboardAccountProvider = activeAccountIdProvider;

final dashboardDataProvider = FutureProvider<DashboardData>((ref) async {
  ref.watch(financialRevisionProvider);
  final txRepo = ref.watch(transactionRepositoryProvider);
  final goalRepo = ref.watch(goalRepositoryProvider);
  final budgetRepo = ref.watch(budgetRepositoryProvider);
  final gamificationRepo = ref.watch(gamificationRepositoryProvider);
  final userSettingsRepo = ref.watch(userSettingsRepositoryProvider);
  final accountRepo = ref.watch(accountRepositoryProvider);
  final catalog = await ref.watch(categoryCatalogProvider.future);
  final range =
      effectiveTransactionsRange(ref.watch(transactionsDateRangeProvider));
  // These reads are independent. Starting them together keeps a dashboard
  // refresh to one network round-trip instead of three when Supabase-primary
  // repositories are active.
  final settingsFuture = userSettingsRepo.getSettings();
  final accountsFuture = accountRepo.getAll();
  // C-9 — this provider is a READ. It must not create accounts or reassign
  // transactions: both repositories enqueue sync intent, so a mutating read
  // turned merely opening Home into durable financial state and cloud writes
  // (the same fault as F-020, where browsing rewrote the default account).
  //
  // The legacy per-currency repair now runs once at startup as an explicit
  // command — see AccountCurrencyRepairService, invoked by BootstrapRunner
  // before the financial UI is marked usable. A currency first seen AFTER
  // startup still gets its account at WRITE time, in the capture path
  // (`add_transaction_usecase.dart`, `_accountForCurrency`), so nothing here
  // depends on the read repairing anything.
  final (settings, accounts) = await (settingsFuture, accountsFuture).wait;
  final selectedAccountId = ref.watch(dashboardAccountProvider);
  AccountEntity? selectedAccount;
  AccountEntity? defaultAccount;
  for (final account in accounts) {
    if (account.id == selectedAccountId) selectedAccount = account;
    if (account.isDefault) defaultAccount = account;
  }
  // الحساب المختار غير موجود (حُذف) → ارجع للحساب الافتراضي، وليس كل الحسابات.
  final activeAccount = selectedAccount ??
      defaultAccount ??
      (accounts.isEmpty ? null : accounts.first);
  final accountId = activeAccount?.id;
  // The dashboard is a single-currency surface: a selected/default account is
  // authoritative; without an account, fall back to the base display currency.
  final displayCurrency = accountId != null
      ? activeAccount!.currency
      : await ref.watch(baseCurrencyProvider.future);

  final now = DateTime.now();
  final rangeStart =
      DateTime(range.from.year, range.from.month, range.from.day);
  final rangeEnd = range.to.isAfter(now) ? now : range.to;
  final daysInRange =
      rangeEnd.difference(rangeStart).inDays.abs().clamp(1, 3660) + 1;
  final previousStart = rangeStart.subtract(Duration(days: daysInRange));
  // MALI-028: the previous period ends where the current one begins — a genuine
  // exclusive boundary, not an epsilon-adjusted last instant.
  final previousEnd = rangeStart;
  final today = DateTime(now.year, now.month, now.day);
  final weekStart =
      today.subtract(Duration(days: (now.weekday - DateTime.saturday) % 7));
  final prevWeekStart = weekStart.subtract(const Duration(days: 7));

  // سارف/دخل الشهر ثابتان على الشهر الحالي بغض النظر عن الفلتر المختار.
  final calendarMonthStart = DateTime(now.year, now.month, 1);
  // MALI-063n: every total comes from the canonical Drift aggregates (the
  // dormant Supabase summary path is retired). Independent reads start together
  // so a refresh reflects a newly-saved transaction as soon as the slowest read
  // completes.
  final balanceFuture = txRepo.latestBalanceAfter(accountId: accountId);
  final thisMonthExpensesFuture = txRepo.expenseTotalBetween(
      from: calendarMonthStart,
      to: now,
      currency: displayCurrency,
      accountId: accountId);
  final thisMonthIncomeFuture = txRepo.incomeTotalBetween(
      from: calendarMonthStart,
      to: now,
      currency: displayCurrency,
      accountId: accountId);
  final prevMonthExpensesFuture = txRepo.expenseTotalBetween(
      from: previousStart,
      to: previousEnd,
      currency: displayCurrency,
      accountId: accountId);
  final weekSpendFuture = txRepo.expenseTotalBetween(
      from: weekStart,
      to: now,
      currency: displayCurrency,
      accountId: accountId);
  final todaySpendFuture = txRepo.expenseTotalBetween(
      from: today, to: now, currency: displayCurrency, accountId: accountId);
  final todayIncomeFuture = txRepo.incomeTotalBetween(
      from: today, to: now, currency: displayCurrency, accountId: accountId);
  final weekIncomeFuture = txRepo.incomeTotalBetween(
      from: weekStart,
      to: now,
      currency: displayCurrency,
      accountId: accountId);
  final previousWeekSpendFuture = txRepo.expenseTotalBetween(
      from: prevWeekStart,
      to: weekStart,
      currency: displayCurrency,
      accountId: accountId);
  final rangeExpenseFuture = txRepo.expenseTotalBetween(
      from: rangeStart,
      to: rangeEnd,
      currency: displayCurrency,
      accountId: accountId);
  final rangeIncomeFuture = txRepo.incomeTotalBetween(
      from: rangeStart,
      to: rangeEnd,
      currency: displayCurrency,
      accountId: accountId);
  final (
    thisMonthExpenses,
    thisMonthIncome,
    prevMonthExpenses,
    weekSpend,
    todaySpend,
    todayIncome,
    weekIncome,
    previousWeekSpend,
  ) = await (
    thisMonthExpensesFuture,
    thisMonthIncomeFuture,
    prevMonthExpensesFuture,
    weekSpendFuture,
    todaySpendFuture,
    todayIncomeFuture,
    weekIncomeFuture,
    previousWeekSpendFuture,
  ).wait;
  // Dart's tuple `.wait` extension tops out at 8 elements, so the remaining
  // totals are awaited separately (still concurrently — their futures were
  // started above alongside everything else).
  final (rangeExpense, rangeIncome, rawBalance) =
      await (rangeExpenseFuture, rangeIncomeFuture, balanceFuture).wait;
  final balance =
      rawBalance?.currency == displayCurrency.toUpperCase() ? rawBalance : null;
  // B2-C — the 3 most-recent pending rows via a bounded SQL query (was a
  // .where(...).take(3) over the whole ledger). Same scope: pending status,
  // active-account (or all when none).
  final pendingReview = await txRepo.getTransactionPage(
    limit: 3,
    filter: TransactionPageFilter(pendingOnly: true, accountId: accountId),
  );
  final pendingReviewTotal = Money.sum(
    pendingReview
        .where(
            (tx) => tx.currency.toUpperCase() == displayCurrency.toUpperCase())
        .map((tx) => tx.amountMoney),
    displayCurrency,
  );
  final saved = prevMonthExpenses - thisMonthExpenses;
  // Start the remaining independent sections before awaiting any one of them.
  // This is especially important with direct Supabase repositories, where
  // every aggregate is otherwise a separate network wait.
  final allBudgetsFuture = budgetRepo.getAll();
  final breakdownFuture = txRepo.categoryBreakdown(
      from: rangeStart,
      to: rangeEnd,
      currency: displayCurrency,
      accountId: accountId);
  final dailySpendTrendFuture = txRepo.dailyExpenseTotals(
      from: rangeStart,
      to: rangeEnd,
      currency: displayCurrency,
      accountId: accountId);
  final weeklyDailySpendFuture = txRepo.dailyExpenseTotals(
    from: weekStart,
    to: now,
    currency: displayCurrency,
    accountId: accountId,
  );
  final topMerchantsFuture = txRepo.merchantBreakdown(
    from: rangeStart,
    to: rangeEnd,
    currency: displayCurrency,
    limit: 5,
    accountId: accountId,
  );
  final recentFuture = txRepo.getRecent(limit: 50, accountId: accountId);
  final streakFuture = gamificationRepo.getStreak();
  final subscriptionsFuture = txRepo.recurringCandidates(accountId: accountId);
  final goalsFuture = goalRepo.getAll();

  final (
    allBudgets,
    breakdown,
    dailySpendRows,
    weeklyDailySpend,
    topMerchants,
    recentRows,
    streak,
    subscriptionRows,
    goals,
  ) = await (
    allBudgetsFuture,
    breakdownFuture,
    dailySpendTrendFuture,
    weeklyDailySpendFuture,
    topMerchantsFuture,
    recentFuture,
    streakFuture,
    subscriptionsFuture,
    goalsFuture,
  ).wait;
  final activeBudgets = allBudgets.where((budget) {
    if (!budget.isActive) return false;
    if (budget.currency.toUpperCase() != displayCurrency.toUpperCase()) {
      return false;
    }
    return accountId == null
        ? budget.accountId == null
        : budget.accountId == accountId;
  }).toList(growable: false);
  BudgetEntity? allExpensesFor(BudgetPeriod period) => activeBudgets
      .where((budget) => budget.isAllExpenses && budget.period == period)
      .fold<BudgetEntity?>(null, (prev, budget) => budget);

  final dailyBudget = allExpensesFor(BudgetPeriod.daily);
  final weeklyBudget = allExpensesFor(BudgetPeriod.weekly);
  final monthlyBudget = allExpensesFor(BudgetPeriod.monthly);
  final dailyBudgetLimit =
      dailyBudget?.amountMoney ?? Money.zero(displayCurrency);
  final weeklyBudgetLimit =
      weeklyBudget?.amountMoney ?? Money.zero(displayCurrency);
  var monthlyBudgetLimit =
      monthlyBudget?.amountMoney ?? Money.zero(displayCurrency);

  // لو المستخدم وزّع دخله على مظاريف شهرية ومفيش ميزانية شهرية عامة،
  // اعرض مجموع المظاريف كحد صرف شهري في الداشبورد بدون double count.
  if (monthlyBudgetLimit.isZero || monthlyBudgetLimit.isNegative) {
    monthlyBudgetLimit = Money.sum(
      activeBudgets
          .where((b) =>
              !b.isAllExpenses &&
              b.period == BudgetPeriod.monthly &&
              // §16/§6: only same-currency budgets fold into the display total —
              // never Money(EGP)+Money(SAR).
              b.currency.toUpperCase() == displayCurrency.toUpperCase())
          .map((b) => b.amountMoney),
      displayCurrency,
    );
  }
  final monthlyBudgetRatio = monthlyBudgetLimit.isZero
      ? 0.0
      : thisMonthExpenses.toDouble() / monthlyBudgetLimit.toDouble();

  final accountMap = {for (final a in accounts) a.id: a.name};
  final budgetProgress = await Future.wait(activeBudgets.map((budget) async {
    // MALI-049n: consumption comes from the budget's OWN stored period (via the
    // canonical resolver), NEVER the dashboard filter range — so a monthly
    // budget stays monthly when the filter is "last 90 days", a weekly budget
    // uses the canonical Saturday-start week, and the ring matches budget
    // detail / the repository aggregate for the same scope.
    final period = resolveBudgetPeriod(budget, now);
    final bSpent = await budgetSpent(
      txRepo,
      budget,
      period,
      fallbackAccountId: accountId,
    );
    final bRatio = budget.amountMoney.isZero
        ? 0.0
        : bSpent.toDouble() / budget.amountMoney.toDouble();
    final catView = catalog.byId(budget.categoryId);
    return DashboardBudgetEntry(
      budgetId: budget.id,
      label: budget.isAllExpenses
          ? 'كل المصروفات'
          : (catView?.nameAr ?? 'ميزانية'),
      spent: bSpent,
      limit: budget.amountMoney,
      ratio: bRatio,
      period: budget.period,
      accountId: budget.accountId,
      accountName:
          budget.accountId != null ? accountMap[budget.accountId] : null,
    );
  }));

  final totalSpend =
      Money.sum(breakdown.map((item) => item.total), displayCurrency);
  final topCategories = <CategorySlice>[];
  for (final item in breakdown.take(3)) {
    final view =
        catalog.byId(item.categoryId) ?? catalog.byKey(item.categoryId);
    if (view == null) continue;
    topCategories.add(
      CategorySlice(
        category: view,
        total: item.total,
        percent: totalSpend.isZero
            ? 0
            : item.total.toDouble() / totalSpend.toDouble(),
        count: item.count,
      ),
    );
  }
  final dailySpendTrend =
      dailySpendRows.map((day) => day.total.toDouble()).toList(growable: false);

  final recent = recentRows
      .where((tx) =>
          // Half-open [rangeStart, rangeEnd) — consistent with the aggregates.
          !tx.occurredAt.isBefore(rangeStart) &&
          tx.occurredAt.isBefore(rangeEnd))
      .take(10)
      .toList(growable: false);
  // الداشبورد يعرض عملة الحساب النشط فقط لتجنب جمع عملات مختلفة في رقم واحد.
  const currencyTotals = <CurrencyTotal>[];
  final subscriptions = subscriptionRows
      .where((item) =>
          item.currency.toUpperCase() == displayCurrency.toUpperCase())
      .take(3)
      .toList(growable: false);
  // §16 correction: subscriptions are already filtered to the display currency
  // above, so the monthly estimate total is an EXACT same-currency Money.sum —
  // never a double fold, never cross-currency.
  final subscriptionsMonthlyTotal = Money.sum(
    subscriptions.map((item) => item.estimatedAmountMoney),
    displayCurrency,
  );
  final projectedMonthSpend = daysInRange == 0
      ? thisMonthExpenses.toDouble()
      : (thisMonthExpenses.toDouble() / daysInRange) * 30;

  final activeGoal = goals
      .where((g) =>
          g.status == 'active' &&
          g.currency.toUpperCase() == displayCurrency.toUpperCase() &&
          (accountId == null || g.accountId == accountId))
      .fold<GoalEntity?>(null, (best, g) {
    if (best == null) return g;
    final progress = g.targetMoney.isZero
        ? 0.0
        : g.savedMoney.toDouble() / g.targetMoney.toDouble();
    final bestProgress = best.targetMoney.isZero
        ? 0.0
        : best.savedMoney.toDouble() / best.targetMoney.toDouble();
    return progress > bestProgress ? g : best;
  });

  return DashboardData(
    savedThisMonth: saved,
    spentThisMonth: thisMonthExpenses,
    incomeThisMonth: thisMonthIncome,
    todaySpend: todaySpend,
    todayIncome: todayIncome,
    weekIncome: weekIncome,
    balance: balance,
    dailyBudgetLimit: dailyBudgetLimit,
    weeklyBudgetLimit: weeklyBudgetLimit,
    monthlyBudgetLimit: monthlyBudgetLimit,
    monthlyBudgetRatio: monthlyBudgetRatio,
    budgetPeriod: monthlyBudgetLimit.isNegative || monthlyBudgetLimit.isZero
        ? null
        : BudgetPeriod.monthly,
    currency: displayCurrency,
    streak: streak,
    topCategories: topCategories,
    dailySpendTrend: dailySpendTrend,
    weeklyDailySpend: weeklyDailySpend,
    topMerchants: topMerchants,
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
    budgetProgress: budgetProgress,
    activeGoal: activeGoal,
    rangeExpense: rangeExpense,
    rangeIncome: rangeIncome,
  );
});
