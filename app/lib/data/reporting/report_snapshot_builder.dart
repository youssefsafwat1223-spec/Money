import '../../domain/entities/report_models.dart';
import '../../domain/entities/transaction_entity.dart';
import '../../domain/reporting/date_range.dart';
import '../../domain/reporting/metrics/report_period_resolver.dart';
import '../../domain/reporting/report_data_snapshot.dart';
import '../../domain/entities/bill_entity.dart';
import '../../domain/reporting/report_request.dart';
import '../../domain/repositories/account_repository.dart';
import '../../domain/repositories/bill_repository.dart';
import '../../domain/repositories/category_repository.dart';
import '../../domain/repositories/goal_repository.dart';
import '../../domain/repositories/transaction_repository.dart';
import '../../domain/usecases/budget_progress_usecase.dart';

/// Collects one immutable [ReportDataSnapshot] for a [ReportRequest] by reading
/// the repositories in a single pass.
///
/// This is the only report layer that touches repositories. It does **not**
/// depend on Riverpod — repositories are injected — so it is testable with the
/// app's standard in-memory Drift harness. Downstream (metrics, composition,
/// rendering) consumes only the returned snapshot.
///
/// Currency handling mirrors the app's constraints: multi-currency is never
/// summed for the per-currency view. `currencyTotalsBetween` has **no account
/// filter**, so a single-account scope cannot use it — instead the account's own
/// currency is paired with its `expenseTotalBetween`/`incomeTotalBetween`.
class ReportSnapshotBuilder {
  ReportSnapshotBuilder({
    required TransactionRepository transactions,
    required AccountRepository accounts,
    required CategoryRepository categories,
    BudgetProgressUseCase? budgets,
    BillRepository? bills,
    GoalRepository? goals,
    DateTime Function()? clock,
    ReportPeriodResolver resolver = const ReportPeriodResolver(),
  })  : _transactions = transactions,
        _accounts = accounts,
        _categories = categories,
        _budgets = budgets,
        _bills = bills,
        _goals = goals,
        _clock = clock ?? DateTime.now,
        _resolver = resolver;

  final TransactionRepository _transactions;
  final AccountRepository _accounts;
  final CategoryRepository _categories;
  final BudgetProgressUseCase? _budgets;
  final BillRepository? _bills;
  final GoalRepository? _goals;
  final DateTime Function() _clock;
  final ReportPeriodResolver _resolver;

  static const int _largestLimit = 10;
  static const int _merchantLimit = 10;

  Future<ReportDataSnapshot> build(ReportRequest request) async {
    final now = _clock();
    final resolved = _resolver.resolve(request.period, now: now);
    final range = resolved.range;
    final previous = resolved.previousRange;
    final accountId = request.accountId;

    final fromU = range.from.toUtc();
    final toU = range.to.toUtc();

    final accountsInScope = await _resolveScope(request);
    final baseCurrency = await _baseCurrencyFor(request, accountsInScope);
    final currencyTotals = await _currencyTotalsFor(request, range);
    final previousCurrencyTotals = await _currencyTotalsFor(request, previous);

    final totalExpense = await _transactions.expenseTotalBetween(
        from: fromU, to: toU, accountId: accountId);
    final totalIncome = await _transactions.incomeTotalBetween(
        from: fromU, to: toU, accountId: accountId);
    final categoryBreakdown = await _transactions.categoryBreakdown(
        from: fromU, to: toU, accountId: accountId);
    final categoryMeta = await _categoryMeta();
    final dailyExpense = await _transactions.dailyExpenseTotals(
        from: fromU, to: toU, accountId: accountId);
    final topMerchants = await _transactions.merchantBreakdown(
        from: fromU, to: toU, limit: _merchantLimit, accountId: accountId);
    final latestBalance =
        await _transactions.latestBalanceAfter(accountId: accountId);
    final largest =
        await _largestTransactions(range, accountId, accountsInScope);
    final budgets = await _budgetsFor(now);
    final bills = await _billsFor();
    final goals = await _goalsFor();
    final appendix = request.content.includeTransactionDetails
        ? await _appendixFor(range, accountId)
        : const <TransactionEntity>[];

    return ReportDataSnapshot(
      capturedAt: now,
      request: request,
      range: range,
      previousRange: previous,
      accountsInScope: List.unmodifiable(accountsInScope),
      currencyTotals: List.unmodifiable(currencyTotals),
      previousCurrencyTotals: List.unmodifiable(previousCurrencyTotals),
      totalIncome: totalIncome,
      totalExpense: totalExpense,
      categoryBreakdown: List.unmodifiable(categoryBreakdown),
      categoryMeta: Map.unmodifiable(categoryMeta),
      dailyExpense: List.unmodifiable(dailyExpense),
      topMerchants: List.unmodifiable(topMerchants),
      largestTransactions: List.unmodifiable(largest),
      latestBalance: latestBalance,
      budgets: List.unmodifiable(budgets),
      bills: List.unmodifiable(bills),
      goals: List.unmodifiable(goals),
      appendixTransactions: List.unmodifiable(appendix),
      baseCurrency: baseCurrency,
    );
  }

  Future<String?> _baseCurrencyFor(
      ReportRequest request, List<ReportAccountRef> scope) async {
    if (request.scope is SingleAccountScope) {
      return scope.isEmpty || !scope.first.isAvailable
          ? null
          : scope.first.currency;
    }
    final defaultAccount = await _accounts.getDefault();
    return defaultAccount?.currency;
  }

  /// All confirmed in-period transactions for the appendix, newest first.
  Future<List<TransactionEntity>> _appendixFor(
      DateRange range, String? accountId) async {
    final fromU = range.from.toUtc();
    final toU = range.to.toUtc();
    final all = await _transactions.getAll();
    final rows = all
        .where((t) =>
            t.status == TransactionStatus.confirmed &&
            !t.occurredAt.toUtc().isBefore(fromU) &&
            t.occurredAt.toUtc().isBefore(toU) &&
            (accountId == null || t.accountId == accountId))
        .toList()
      ..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
    return rows;
  }

  Future<List<ReportBudgetLite>> _budgetsFor(DateTime now) async {
    final useCase = _budgets;
    if (useCase == null) return const <ReportBudgetLite>[];
    final snapshot = await useCase.call(now: now);
    return <ReportBudgetLite>[
      for (final e in snapshot.entries)
        ReportBudgetLite(
          categoryId: e.budget.categoryId,
          spent: e.spent,
          limit: e.budget.amount,
          ratio: e.ratio,
          health: e.health.name,
        ),
    ];
  }

  Future<List<ReportBillLite>> _billsFor() async {
    final repo = _bills;
    if (repo == null) return const <ReportBillLite>[];
    final all = await repo.getAll();
    final active = all.where((b) => b.status == BillStatus.active).toList()
      ..sort((a, b) => a.nextDueDate.compareTo(b.nextDueDate));
    return <ReportBillLite>[
      for (final b in active)
        ReportBillLite(
          name: b.name,
          amount: b.amount,
          currency: b.currency,
          dueDate: b.nextDueDate,
          isSubscription: b.type == BillType.subscription,
          status: b.status.name,
        ),
    ];
  }

  Future<List<ReportGoalLite>> _goalsFor() async {
    final repo = _goals;
    if (repo == null) return const <ReportGoalLite>[];
    final all = await repo.getAll();
    return <ReportGoalLite>[
      for (final g in all)
        ReportGoalLite(
          name: g.name,
          saved: g.savedAmount,
          target: g.targetAmount,
          progress: g.targetAmount <= 0
              ? 0.0
              : (g.savedAmount / g.targetAmount).clamp(0.0, 1.0).toDouble(),
          deadline: g.deadline,
        ),
    ];
  }

  Future<Map<String, ReportCategoryMeta>> _categoryMeta() async {
    final categories = await _categories.getAll();
    return <String, ReportCategoryMeta>{
      for (final c in categories)
        c.id: ReportCategoryMeta(
          id: c.id,
          key: c.key,
          name: c.nameAr,
          colorHex: c.color,
        ),
    };
  }

  Future<List<ReportAccountRef>> _resolveScope(ReportRequest request) async {
    final scope = request.scope;
    if (scope is SingleAccountScope) {
      final account = await _accounts.getById(scope.accountId);
      if (account == null) {
        return const <ReportAccountRef>[ReportAccountRef.unavailable];
      }
      return <ReportAccountRef>[ReportAccountRef.fromEntity(account)];
    }
    final all = await _accounts.getAll();
    return all.map(ReportAccountRef.fromEntity).toList();
  }

  Future<List<CurrencyTotal>> _currencyTotalsFor(
      ReportRequest request, DateRange range) async {
    final fromU = range.from.toUtc();
    final toU = range.to.toUtc();
    final scope = request.scope;
    if (scope is SingleAccountScope) {
      final account = await _accounts.getById(scope.accountId);
      final expense = await _transactions.expenseTotalBetween(
          from: fromU, to: toU, accountId: scope.accountId);
      final income = await _transactions.incomeTotalBetween(
          from: fromU, to: toU, accountId: scope.accountId);
      return <CurrencyTotal>[
        CurrencyTotal(
          currency: account?.currency ?? '',
          expense: expense,
          income: income,
        ),
      ];
    }
    return _transactions.currencyTotalsBetween(from: fromU, to: toU);
  }

  Future<List<TransactionEntity>> _largestTransactions(
    DateRange range,
    String? accountId,
    List<ReportAccountRef> accountsInScope,
  ) async {
    final fromU = range.from.toUtc();
    final toU = range.to.toUtc();
    // Exclude flagged accounts only in the combined (all-accounts) view. A
    // single-account report still lists that account's own largest rows even
    // if it is flagged exclude_from_totals — matching the repository totals.
    final excludedAccountIds = <String>{
      if (accountId == null)
        for (final account in accountsInScope)
          if (account.excludeFromTotals && account.id != null) account.id!,
    };
    String? selectedCurrency;
    if (accountId != null) {
      for (final account in accountsInScope) {
        if (account.id == accountId && account.isAvailable) {
          selectedCurrency = account.currency;
          break;
        }
      }
    }
    final all = await _transactions.getAll();
    final filtered = all
        .where((t) =>
            t.status == TransactionStatus.confirmed &&
            (t.type == TransactionTypeEntity.payment ||
                t.type == TransactionTypeEntity.withdrawal) &&
            (t.accountId == null ||
                !excludedAccountIds.contains(t.accountId)) &&
            !t.occurredAt.toUtc().isBefore(fromU) &&
            t.occurredAt.toUtc().isBefore(toU) &&
            (accountId == null ||
                t.accountId == accountId ||
                (t.accountId == null &&
                    selectedCurrency != null &&
                    t.currency.toUpperCase() ==
                        selectedCurrency.toUpperCase())))
        .toList()
      ..sort((a, b) => b.amount.compareTo(a.amount));
    return filtered.take(_largestLimit).toList();
  }
}
