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

String _normalizeCurrency(String currency) => currency.trim().toUpperCase();

/// B2-C — ensures a per-currency account exists and backfills null-account
/// transactions WITHOUT loading the whole ledger. [presentCurrencies] is the
/// bounded distinct-currency set (all-time); the backfill drains only the
/// null-account rows (normally empty after the first pass). Returns the accounts.
Future<List<AccountEntity>> _ensureCurrencyAccounts({
  required AccountRepository accountRepo,
  required TransactionRepository txRepo,
  required List<AccountEntity> initialAccounts,
  required List<String> presentCurrencies,
  required String fallbackCurrency,
}) async {
  var accounts = List<AccountEntity>.of(initialAccounts);
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

  for (final raw in presentCurrencies) {
    final currency = _normalizeCurrency(raw);
    if (currency.isNotEmpty && !byCurrency.containsKey(currency)) {
      await createAccount(currency);
    }
  }

  // Backfill ONLY null-account transactions via a bounded keyset drain (the
  // null-account set shrinks to empty after the first pass — never the whole
  // ledger). A row whose currency has no account (e.g. blank currency) is left
  // as-is, exactly as before. Advancing past a processed page never re-fetches
  // or skips: updated rows leave the null-account set, un-updated ones fall
  // before the cursor and are retried on a later dashboard load (best-effort).
  DateTime? beforeOccurredAt;
  String? beforeId;
  const pageSize = 500;
  while (true) {
    final page = await txRepo.transactionsWithoutAccount(
      beforeOccurredAt: beforeOccurredAt,
      beforeId: beforeId,
      limit: pageSize,
    );
    if (page.isEmpty) break;
    for (final tx in page) {
      final account = byCurrency[_normalizeCurrency(tx.currency)];
      if (account == null) continue;
      try {
        await txRepo.updateAccount(
            transactionId: tx.id, accountId: account.id);
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
    if (page.length < pageSize) break;
    final last = page.last;
    beforeOccurredAt = last.occurredAt;
    beforeId = last.id;
  }

  return accounts;
}

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
  final initialAccountsFuture = accountRepo.getAll();
  // B2-C — the bounded distinct-currency set, not the whole ledger.
  final presentCurrenciesFuture = txRepo.distinctCurrencies();
  final (settings, initialAccounts, presentCurrencies) = await (
    settingsFuture,
    initialAccountsFuture,
    presentCurrenciesFuture,
  ).wait;
  final accounts = await _ensureCurrencyAccounts(
    accountRepo: accountRepo,
    txRepo: txRepo,
    initialAccounts: initialAccounts,
    presentCurrencies: presentCurrencies,
    fallbackCurrency: settings.currency,
  );
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
      from: calendarMonthStart, to: now, accountId: accountId);
  final thisMonthIncomeFuture = txRepo.incomeTotalBetween(
      from: calendarMonthStart, to: now, accountId: accountId);
  final prevMonthExpensesFuture = txRepo.expenseTotalBetween(
      from: previousStart, to: previousEnd, accountId: accountId);
  final weekSpendFuture = txRepo.expenseTotalBetween(
      from: weekStart, to: now, accountId: accountId);
  final todaySpendFuture =
      txRepo.expenseTotalBetween(from: today, to: now, accountId: accountId);
  final todayIncomeFuture =
      txRepo.incomeTotalBetween(from: today, to: now, accountId: accountId);
  final weekIncomeFuture = txRepo.incomeTotalBetween(
      from: weekStart, to: now, accountId: accountId);
  final previousWeekSpendFuture = txRepo.expenseTotalBetween(
      from: prevWeekStart, to: weekStart, accountId: accountId);
  final rangeExpenseFuture = txRepo.expenseTotalBetween(
      from: rangeStart, to: rangeEnd, accountId: accountId);
  final rangeIncomeFuture = txRepo.incomeTotalBetween(
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
  // Dart's tuple `.wait` extension tops out at 8 elements, so the remaining
  // totals are awaited separately (still concurrently — their futures were
  // started above alongside everything else).
  final (rangeExpense, rangeIncome, balance) =
      await (rangeExpenseFuture, rangeIncomeFuture, balanceFuture).wait;
  // B2-C — the 3 most-recent pending rows via a bounded SQL query (was a
  // .where(...).take(3) over the whole ledger). Same scope: pending status,
  // active-account (or all when none).
  final pendingReview = await txRepo.getTransactionPage(
    limit: 3,
    filter: TransactionPageFilter(pendingOnly: true, accountId: accountId),
  );
  final pendingReviewTotal =
      pendingReview.fold<double>(0, (sum, tx) => sum + tx.amount);
  final saved = prevMonthExpenses - thisMonthExpenses;
  // Start the remaining independent sections before awaiting any one of them.
  // This is especially important with direct Supabase repositories, where
  // every aggregate is otherwise a separate network wait.
  final allBudgetsFuture = budgetRepo.getAll();
  final breakdownFuture = txRepo.categoryBreakdown(
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
          // Half-open [rangeStart, rangeEnd) — consistent with the aggregates.
          !tx.occurredAt.isBefore(rangeStart) &&
          tx.occurredAt.isBefore(rangeEnd))
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
