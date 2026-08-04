import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../domain/entities/account_entity.dart';
import '../../domain/entities/budget_entity.dart';
import '../../domain/entities/goal_entity.dart';
import '../../domain/entities/report_models.dart';
import '../../domain/entities/supporting_entities.dart';
import '../../domain/entities/transaction_entity.dart';
import '../../domain/errors/repo_exceptions.dart';
import '../../domain/finance/budget_period.dart';
import '../../domain/repositories/account_repository.dart';
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
  final double spent;
  final double limit;
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
  final double total;
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

  final double savedThisMonth;
  final double spentThisMonth;
  final double incomeThisMonth;
  final double todaySpend;
  final double todayIncome;
  final double weekIncome;
  final double? balance;
  final double dailyBudgetLimit;
  final double weeklyBudgetLimit;
  final double monthlyBudgetLimit;
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
  final double pendingReviewTotal;
  final double weekSpend;
  final double previousWeekSpend;
  final double projectedMonthSpend;
  final List<RecurringCandidate> subscriptions;
  final double subscriptionsMonthlyTotal;
  final TransactionsDateRange range;
  final List<CurrencyTotal> currencyTotals;
  final List<DashboardBudgetEntry> budgetProgress;
  final GoalEntity? activeGoal;

  /// Expense/income totals for the currently selected filter [range] — not
  /// tied to the calendar month, unlike [spentThisMonth]/[incomeThisMonth].
  /// Feeds the dashboard's income-vs-expense summary card.
  final double rangeExpense;
  final double rangeIncome;

  /// عرض إجماليات منفصلة لكل عملة (عند تعدّد العملات في «كل الحسابات»).
  bool get hasMultipleCurrencies => currencyTotals.length > 1;

  bool get isEmpty => recent.isEmpty;
  int get pendingReviewCount => pendingReview.length;
  int get subscriptionsCount => subscriptions.length;

  double get weekChangeRatio {
    if (previousWeekSpend == 0) return weekSpend == 0 ? 0 : 1;
    return (weekSpend - previousWeekSpend) / previousWeekSpend;
  }

  // ─── درجة قرش ───────────────────────────────────────────────────────────────

  /// التزام بالميزانية: 0-100. إذا لم تُحدَّد ميزانية → 75 (محايد).
  double get budgetScore {
    if (monthlyBudgetLimit <= 0) return 75;
    return ((1 - monthlyBudgetRatio).clamp(0.0, 1.0) * 100);
  }

  /// معدل الادخار: 0-100. إذا لم يوجد دخل → 50 (محايد).
  double get savingsScore {
    if (incomeThisMonth <= 0) return 50;
    return (((incomeThisMonth - spentThisMonth) / incomeThisMonth)
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

class _CurrencyAccountState {
  const _CurrencyAccountState({
    required this.accounts,
    required this.transactions,
  });

  final List<AccountEntity> accounts;
  final List<TransactionEntity> transactions;
}

String _normalizeCurrency(String currency) => currency.trim().toUpperCase();

Future<_CurrencyAccountState> _ensureCurrencyAccounts({
  required AccountRepository accountRepo,
  required TransactionRepository txRepo,
  required List<AccountEntity> initialAccounts,
  required List<TransactionEntity> initialTransactions,
  required String fallbackCurrency,
}) async {
  var accounts = List<AccountEntity>.of(initialAccounts);
  var transactions = List<TransactionEntity>.of(initialTransactions);
  final byCurrency = <String, AccountEntity>{
    for (final account in accounts)
      _normalizeCurrency(account.currency): account,
  };

  Future<AccountEntity> createAccount(String currency) async {
    final now = DateTime.now().toUtc();
    final account = await accountRepo.create(
      AccountEntity(
        id: '',
        name: 'حساب $currency',
        currency: currency,
        type: AccountType.bank,
        initialBalance: null,
        currentBalance: null,
        isDefault: accounts.isEmpty,
        sortOrder: accounts.length,
        createdAt: now,
        updatedAt: now,
      ),
    );
    accounts = [...accounts, account];
    byCurrency[currency] = account;
    return account;
  }

  final baseCurrency = _normalizeCurrency(fallbackCurrency);
  if (accounts.isEmpty && baseCurrency.isNotEmpty) {
    await createAccount(baseCurrency);
  }

  final transactionCurrencies = {
    for (final tx in transactions)
      if (_normalizeCurrency(tx.currency).isNotEmpty)
        _normalizeCurrency(tx.currency),
  };
  for (final currency in transactionCurrencies) {
    if (!byCurrency.containsKey(currency)) {
      await createAccount(currency);
    }
  }

  var changed = false;
  transactions = [
    for (final tx in transactions)
      if (tx.accountId == null &&
          byCurrency.containsKey(_normalizeCurrency(tx.currency)))
        () {
          final account = byCurrency[_normalizeCurrency(tx.currency)]!;
          changed = true;
          return tx.copyWith(accountId: account.id);
        }()
      else
        tx,
  ];

  if (changed) {
    for (final tx in transactions) {
      if (tx.accountId == null) continue;
      final original =
          initialTransactions.firstWhere((item) => item.id == tx.id);
      if (original.accountId == null && original.accountId != tx.accountId) {
        try {
          await txRepo.updateAccount(
              transactionId: tx.id, accountId: tx.accountId!);
        } on RepoException catch (e) {
          // مصالحة في الخلفية بلا واجهة مستخدم — نسجّل ونكمل الباقي بدل
          // فشل حساب الـ dashboard كله بسبب صف واحد.
          if (kDebugMode) {
            debugPrint(
              '[Dashboard] account reconciliation skipped: ${e.runtimeType}',
            );
          }
        }
      }
    }
  }

  return _CurrencyAccountState(
    accounts: accounts,
    transactions: transactions,
  );
}

final dashboardDataProvider = FutureProvider<DashboardData>((ref) async {
  ref.watch(dbRevisionProvider);
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
  final initialAccountsFuture = accountRepo.getAll();
  final initialTransactionsFuture = txRepo.getAll();
  final (settings, initialAccounts, initialTransactions) = await (
    settingsFuture,
    initialAccountsFuture,
    initialTransactionsFuture,
  ).wait;
  final currencyAccountState = await _ensureCurrencyAccounts(
    accountRepo: accountRepo,
    txRepo: txRepo,
    initialAccounts: initialAccounts,
    initialTransactions: initialTransactions,
    fallbackCurrency: settings.currency,
  );
  final accounts = currencyAccountState.accounts;
  final allTransactions = currencyAccountState.transactions;
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
  final useSupabaseSummary = supabaseDashboardSummaryEnabled();
  final summaryService = ref.watch(supabaseFinancialSummaryServiceProvider);

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

  // سارف/دخل الشهر ثابتان على الشهر الحالي بغض النظر عن الفلتر المختار.
  final calendarMonthStart = DateTime(now.year, now.month, 1);
  // A refresh used to await every summary RPC serially while Riverpod kept
  // showing the previous numbers. Start all independent summaries together so
  // a newly-saved transaction is reflected as soon as the slowest request
  // completes, rather than after the sum of all request times.
  final monthSummaryFuture = useSupabaseSummary
      ? summaryService.periodSummary(
          from: calendarMonthStart,
          to: now.add(const Duration(microseconds: 1)),
          accountId: accountId,
        )
      : Future.value(null);
  final previousRangeSummaryFuture = useSupabaseSummary
      ? summaryService.periodSummary(
          from: previousStart,
          to: rangeStart,
          accountId: accountId,
        )
      : Future.value(null);
  final weekSummaryFuture = useSupabaseSummary
      ? summaryService.periodSummary(
          from: weekStart,
          to: now.add(const Duration(microseconds: 1)),
          accountId: accountId,
        )
      : Future.value(null);
  final todaySummaryFuture = useSupabaseSummary
      ? summaryService.periodSummary(
          from: today,
          to: now.add(const Duration(microseconds: 1)),
          accountId: accountId,
        )
      : Future.value(null);
  final previousWeekSummaryFuture = useSupabaseSummary
      ? summaryService.periodSummary(
          from: prevWeekStart,
          to: weekStart,
          accountId: accountId,
        )
      : Future.value(null);
  final balanceFuture = useSupabaseSummary && accountId != null
      ? summaryService
          .accountBalance(accountId)
          .then((summary) => summary?.effectiveBalance)
      : txRepo.latestBalanceAfter(accountId: accountId);
  // The selected filter range's own income/expense totals — distinct from
  // monthSummary (always calendar-month) and previousRangeSummary (the prior
  // period, for comparison). Feeds the dashboard's income-vs-expense summary.
  final rangeSummaryFuture = useSupabaseSummary
      ? summaryService.periodSummary(
          from: rangeStart,
          to: rangeEnd.add(const Duration(microseconds: 1)),
          accountId: accountId,
        )
      : Future.value(null);

  final (
    monthSummary,
    previousRangeSummary,
    weekSummary,
    todaySummary,
    previousWeekSummary,
    balance,
    rangeSummary,
  ) = await (
    monthSummaryFuture,
    previousRangeSummaryFuture,
    weekSummaryFuture,
    todaySummaryFuture,
    previousWeekSummaryFuture,
    balanceFuture,
    rangeSummaryFuture,
  ).wait;

  final thisMonthExpensesFuture = monthSummary != null
      ? Future.value(monthSummary.expense)
      : txRepo.expenseTotalBetween(
          from: calendarMonthStart, to: now, accountId: accountId);
  final thisMonthIncomeFuture = monthSummary != null
      ? Future.value(monthSummary.income)
      : txRepo.incomeTotalBetween(
          from: calendarMonthStart, to: now, accountId: accountId);
  final prevMonthExpensesFuture = previousRangeSummary != null
      ? Future.value(previousRangeSummary.expense)
      : txRepo.expenseTotalBetween(
          from: previousStart,
          to: previousEnd,
          accountId: accountId,
        );
  final weekSpendFuture = weekSummary != null
      ? Future.value(weekSummary.expense)
      : txRepo.expenseTotalBetween(
          from: weekStart, to: now, accountId: accountId);
  final todaySpendFuture = todaySummary != null
      ? Future.value(todaySummary.expense)
      : txRepo.expenseTotalBetween(from: today, to: now, accountId: accountId);
  final todayIncomeFuture = todaySummary != null
      ? Future.value(todaySummary.income)
      : txRepo.incomeTotalBetween(from: today, to: now, accountId: accountId);
  final weekIncomeFuture = weekSummary != null
      ? Future.value(weekSummary.income)
      : txRepo.incomeTotalBetween(
          from: weekStart, to: now, accountId: accountId);
  final previousWeekSpendFuture = previousWeekSummary != null
      ? Future.value(previousWeekSummary.expense)
      : txRepo.expenseTotalBetween(
          from: prevWeekStart,
          to: weekStart,
          accountId: accountId,
        );
  final rangeExpenseFuture = rangeSummary != null
      ? Future.value(rangeSummary.expense)
      : txRepo.expenseTotalBetween(
          from: rangeStart, to: rangeEnd, accountId: accountId);
  final rangeIncomeFuture = rangeSummary != null
      ? Future.value(rangeSummary.income)
      : txRepo.incomeTotalBetween(
          from: rangeStart, to: rangeEnd, accountId: accountId);
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
  // Dart's tuple `.wait` extension tops out at 8 elements, so the two new
  // range totals are awaited separately (still concurrently with each other,
  // and their own futures were already started above alongside everything
  // else — this split only affects how the results are collected).
  final (rangeExpense, rangeIncome) =
      await (rangeExpenseFuture, rangeIncomeFuture).wait;
  final pendingReview = allTransactions
      .where((tx) =>
          tx.status == TransactionStatus.pending &&
          (accountId == null || tx.accountId == accountId))
      .take(3)
      .toList(growable: false);
  final pendingReviewTotal =
      pendingReview.fold<double>(0, (sum, tx) => sum + tx.amount);
  final saved = prevMonthExpenses - thisMonthExpenses;
  // Start the remaining independent sections before awaiting any one of them.
  // This is especially important with direct Supabase repositories, where
  // every aggregate is otherwise a separate network wait.
  final allBudgetsFuture = budgetRepo.getAll();
  final breakdownFuture = useSupabaseSummary
      ? summaryService.categorySummary(
          from: rangeStart,
          to: rangeEnd.add(const Duration(microseconds: 1)),
          accountId: accountId,
        )
      : txRepo.categoryBreakdown(
          from: rangeStart, to: rangeEnd, accountId: accountId);
  final dailySpendTrendFuture = txRepo.dailyExpenseTotals(
      from: rangeStart, to: rangeEnd, accountId: accountId);
  final weeklyDailySpendFuture = txRepo.dailyExpenseTotals(
    from: weekStart,
    to: now,
    accountId: accountId,
  );
  final topMerchantsFuture = txRepo.merchantBreakdown(
    from: rangeStart,
    to: rangeEnd,
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
  final dailyBudgetLimit = dailyBudget?.amount ?? 0;
  final weeklyBudgetLimit = weeklyBudget?.amount ?? 0;
  var monthlyBudgetLimit = monthlyBudget?.amount ?? 0;

  // لو المستخدم وزّع دخله على مظاريف شهرية ومفيش ميزانية شهرية عامة،
  // اعرض مجموع المظاريف كحد صرف شهري في الداشبورد بدون double count.
  if (monthlyBudgetLimit <= 0) {
    monthlyBudgetLimit = activeBudgets
        .where((b) => !b.isAllExpenses && b.period == BudgetPeriod.monthly)
        .fold<double>(0, (sum, b) => sum + b.amount);
  }
  final monthlyBudgetRatio =
      monthlyBudgetLimit == 0 ? 0.0 : thisMonthExpenses / monthlyBudgetLimit;

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
    final bRatio = budget.amount == 0 ? 0.0 : bSpent / budget.amount;
    final catView = catalog.byId(budget.categoryId);
    return DashboardBudgetEntry(
      budgetId: budget.id,
      label: budget.isAllExpenses
          ? 'كل المصروفات'
          : (catView?.nameAr ?? 'ميزانية'),
      spent: bSpent,
      limit: budget.amount,
      ratio: bRatio,
      period: budget.period,
      accountId: budget.accountId,
      accountName:
          budget.accountId != null ? accountMap[budget.accountId] : null,
    );
  }));

  final totalSpend = breakdown.fold<double>(0, (sum, item) => sum + item.total);
  final topCategories = <CategorySlice>[];
  for (final item in breakdown.take(3)) {
    final view =
        catalog.byId(item.categoryId) ?? catalog.byKey(item.categoryId);
    if (view == null) continue;
    topCategories.add(
      CategorySlice(
        category: view,
        total: item.total,
        percent: totalSpend == 0 ? 0 : item.total / totalSpend,
        count: item.count,
      ),
    );
  }
  final dailySpendTrend =
      dailySpendRows.map((day) => day.total).toList(growable: false);

  final recent = recentRows
      .where((tx) =>
          !tx.occurredAt.isBefore(rangeStart) &&
          !tx.occurredAt.isAfter(rangeEnd))
      .take(10)
      .toList(growable: false);
  // الداشبورد يعرض عملة الحساب النشط فقط لتجنب جمع عملات مختلفة في رقم واحد.
  const currencyTotals = <CurrencyTotal>[];
  final subscriptions = subscriptionRows.take(3).toList(growable: false);
  final subscriptionsMonthlyTotal = subscriptions.fold<double>(
    0,
    (sum, item) => sum + item.averageAmount,
  );
  final projectedMonthSpend = daysInRange == 0
      ? thisMonthExpenses
      : (thisMonthExpenses / daysInRange) * 30;

  final activeGoal = goals
      .where((g) =>
          g.status == 'active' &&
          (accountId == null || g.accountId == accountId))
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
    dailyBudgetLimit: dailyBudgetLimit,
    weeklyBudgetLimit: weeklyBudgetLimit,
    monthlyBudgetLimit: monthlyBudgetLimit,
    monthlyBudgetRatio: monthlyBudgetRatio,
    budgetPeriod: monthlyBudgetLimit > 0 ? BudgetPeriod.monthly : null,
    currency: activeAccount?.currency ?? settings.currency,
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
