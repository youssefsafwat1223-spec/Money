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
import '../../domain/repositories/account_repository.dart';
import '../../domain/repositories/transaction_repository.dart';
import '../common/category_catalog.dart';
import '../transactions/transactions_providers.dart';

/// ملخص ميزانية تُعرض في هيدر الداشبورد (showOnHeader = true).
class BudgetHeaderEntry {
  const BudgetHeaderEntry({
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
    required this.budgetsForHeader,
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
  final List<BudgetHeaderEntry> budgetsForHeader;
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
  final settings = await userSettingsRepo.getSettings();
  final initialAccounts = await accountRepo.getAll();
  final initialTransactions = await txRepo.getAll();
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
  final selectedAccount = selectedAccountId == null
      ? null
      : await accountRepo.getById(selectedAccountId);
  // الحساب المختار غير موجود (حُذف) → ارجع للحساب الافتراضي، وليس كل الحسابات.
  final defaultAccount = await accountRepo.getDefault();
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
  final monthSummary = useSupabaseSummary
      ? await summaryService.periodSummary(
          from: calendarMonthStart,
          to: now.add(const Duration(microseconds: 1)),
          accountId: accountId,
        )
      : null;
  final previousRangeSummary = useSupabaseSummary
      ? await summaryService.periodSummary(
          from: previousStart,
          to: rangeStart,
          accountId: accountId,
        )
      : null;
  final weekSummary = useSupabaseSummary
      ? await summaryService.periodSummary(
          from: weekStart,
          to: now.add(const Duration(microseconds: 1)),
          accountId: accountId,
        )
      : null;
  final todaySummary = useSupabaseSummary
      ? await summaryService.periodSummary(
          from: today,
          to: now.add(const Duration(microseconds: 1)),
          accountId: accountId,
        )
      : null;
  final previousWeekSummary = useSupabaseSummary
      ? await summaryService.periodSummary(
          from: prevWeekStart,
          to: weekStart,
          accountId: accountId,
        )
      : null;
  final thisMonthExpenses = monthSummary?.expense ??
      await txRepo.expenseTotalBetween(
          from: calendarMonthStart, to: now, accountId: accountId);
  final thisMonthIncome = monthSummary?.income ??
      await txRepo.incomeTotalBetween(
          from: calendarMonthStart, to: now, accountId: accountId);
  final balance = useSupabaseSummary && accountId != null
      ? (await summaryService.accountBalance(accountId))?.effectiveBalance
      : await txRepo.latestBalanceAfter(accountId: accountId);
  final prevMonthExpenses = previousRangeSummary?.expense ??
      await txRepo.expenseTotalBetween(
        from: previousStart,
        to: previousEnd,
        accountId: accountId,
      );
  final weekSpend = weekSummary?.expense ??
      await txRepo.expenseTotalBetween(
          from: weekStart, to: now, accountId: accountId);
  final todaySpend = todaySummary?.expense ??
      await txRepo.expenseTotalBetween(
          from: today, to: now, accountId: accountId);
  final todayIncome = todaySummary?.income ??
      await txRepo.incomeTotalBetween(
          from: today, to: now, accountId: accountId);
  final weekIncome = weekSummary?.income ??
      await txRepo.incomeTotalBetween(
          from: weekStart, to: now, accountId: accountId);
  final previousWeekSpend = previousWeekSummary?.expense ??
      await txRepo.expenseTotalBetween(
        from: prevWeekStart,
        to: weekStart,
        accountId: accountId,
      );
  final pendingReview = allTransactions
      .where((tx) =>
          tx.status == TransactionStatus.pending &&
          (accountId == null || tx.accountId == accountId))
      .take(3)
      .toList(growable: false);
  final pendingReviewTotal =
      pendingReview.fold<double>(0, (sum, tx) => sum + tx.amount);
  final saved = prevMonthExpenses - thisMonthExpenses;
  final allBudgets = await budgetRepo.getAll();
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

  // ميزانيات الهيدر للحساب النشط فقط.
  final headerBudgets =
      activeBudgets.where((b) => b.showOnHeader).toList(growable: false);
  final accountMap = {for (final a in accounts) a.id: a.name};
  final budgetsForHeader = <BudgetHeaderEntry>[];
  for (final budget in headerBudgets) {
    final ps = switch (budget.period) {
      BudgetPeriod.daily => today,
      BudgetPeriod.weekly =>
        today.subtract(Duration(days: (now.weekday - DateTime.saturday) % 7)),
      BudgetPeriod.monthly => rangeStart,
      BudgetPeriod.yearly => DateTime(now.year, 1, 1),
    };
    final bSpent = budget.isAllExpenses
        ? await txRepo.expenseTotalBetween(
            from: ps, to: now, accountId: budget.accountId)
        : await txRepo.categoryExpenseTotalBetween(
            categoryId: budget.categoryId,
            from: ps,
            to: now,
            accountId: budget.accountId ?? accountId,
          );
    final bRatio = budget.amount == 0 ? 0.0 : bSpent / budget.amount;
    final catView = catalog.byId(budget.categoryId);
    budgetsForHeader.add(BudgetHeaderEntry(
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
    ));
  }

  final breakdown = useSupabaseSummary
      ? await summaryService.categorySummary(
          from: rangeStart,
          to: rangeEnd.add(const Duration(microseconds: 1)),
          accountId: accountId,
        )
      : await txRepo.categoryBreakdown(
          from: rangeStart, to: rangeEnd, accountId: accountId);
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
  final dailySpendTrend = (await txRepo.dailyExpenseTotals(
          from: rangeStart, to: rangeEnd, accountId: accountId))
      .map((day) => day.total)
      .toList(growable: false);
  final weeklyDailySpend = await txRepo.dailyExpenseTotals(
    from: weekStart,
    to: now,
    accountId: accountId,
  );
  final topMerchants = await txRepo.merchantBreakdown(
    from: rangeStart,
    to: rangeEnd,
    limit: 5,
    accountId: accountId,
  );

  final recent = (await txRepo.getRecent(limit: 50, accountId: accountId))
      .where((tx) =>
          !tx.occurredAt.isBefore(rangeStart) &&
          !tx.occurredAt.isAfter(rangeEnd))
      .take(10)
      .toList(growable: false);
  // الداشبورد يعرض عملة الحساب النشط فقط لتجنب جمع عملات مختلفة في رقم واحد.
  const currencyTotals = <CurrencyTotal>[];
  final streak = await gamificationRepo.getStreak();
  final subscriptions = (await txRepo.recurringCandidates(accountId: accountId))
      .take(3)
      .toList(growable: false);
  final subscriptionsMonthlyTotal = subscriptions.fold<double>(
    0,
    (sum, item) => sum + item.averageAmount,
  );
  final projectedMonthSpend = daysInRange == 0
      ? thisMonthExpenses
      : (thisMonthExpenses / daysInRange) * 30;

  final goals = await goalRepo.getAll();
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
    budgetsForHeader: budgetsForHeader,
    activeGoal: activeGoal,
  );
});
