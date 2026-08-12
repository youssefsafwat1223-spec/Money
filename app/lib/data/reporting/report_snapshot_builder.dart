import '../../domain/entities/category_spend.dart';
import '../../domain/entities/report_models.dart';
import '../../domain/entities/transaction_entity.dart';
import '../../domain/finance/money.dart';
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
  // MALI-030 — the appendix is read in bounded keyset pages (never the whole
  // table at once) and hard-capped: a report shows at most [_appendixMaxRows] of
  // the most recent confirmed transactions (documented in PHASE_7 perf contract).
  static const int _appendixPageSize = 500;
  static const int _appendixMaxRows = 5000;

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
    final reportCurrency = _primaryCurrency(currencyTotals, baseCurrency);

    final currentTotal = currencyTotals
        .where((total) => total.currency == reportCurrency)
        .firstOrNull;
    final totalExpense = currentTotal?.expense ?? Money.zero(reportCurrency);
    final totalIncome = currentTotal?.income ?? Money.zero(reportCurrency);
    final categoryBreakdown = await _transactions.categoryBreakdown(
      from: fromU,
      to: toU,
      currency: reportCurrency,
      accountId: accountId,
    );
    // MALI-063n: a per-currency breakdown so the donut/slices never mix
    // currencies. One query per currency actually present in the period.
    final categoryBreakdownByCurrency = <String, List<CategorySpend>>{};
    for (final ct in currencyTotals) {
      if (ct.currency.isEmpty) continue;
      categoryBreakdownByCurrency[ct.currency] =
          await _transactions.categoryBreakdown(
        from: fromU,
        to: toU,
        accountId: accountId,
        currency: ct.currency,
      );
    }
    final categoryMeta = await _categoryMeta();
    final dailyExpense = await _transactions.dailyExpenseTotals(
      from: fromU,
      to: toU,
      currency: reportCurrency,
      accountId: accountId,
    );
    final topMerchants = await _transactions.merchantBreakdown(
      from: fromU,
      to: toU,
      currency: reportCurrency,
      limit: _merchantLimit,
      accountId: accountId,
    );
    final rawLatestBalance =
        await _transactions.latestBalanceAfter(accountId: accountId);
    final latestBalance =
        rawLatestBalance?.currency == reportCurrency ? rawLatestBalance : null;
    final largest = await _largestTransactions(range, accountId);
    final budgets = await _budgetsFor(now);
    final bills = await _billsFor();
    final goals = await _goalsFor();
    final appendixResult = request.content.includeTransactionDetails
        ? await _appendixFor(range, accountId)
        : (rows: const <TransactionEntity>[], omitted: false);
    final appendix = appendixResult.rows;

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
      categoryBreakdownByCurrency: Map.unmodifiable({
        for (final e in categoryBreakdownByCurrency.entries)
          e.key: List<CategorySpend>.unmodifiable(e.value),
      }),
      categoryMeta: Map.unmodifiable(categoryMeta),
      dailyExpense: List.unmodifiable(dailyExpense),
      topMerchants: List.unmodifiable(topMerchants),
      largestTransactions: List.unmodifiable(largest),
      latestBalance: latestBalance,
      budgets: List.unmodifiable(budgets),
      bills: List.unmodifiable(bills),
      goals: List.unmodifiable(goals),
      appendixTransactions: List.unmodifiable(appendix),
      appendixOmittedForSize: appendixResult.omitted,
      appendixRowLimit: appendixResult.omitted ? _appendixMaxRows : 0,
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

  String _primaryCurrency(
    List<CurrencyTotal> totals,
    String? baseCurrency,
  ) {
    final base = baseCurrency?.trim().toUpperCase();
    if (base != null &&
        base.isNotEmpty &&
        totals.any((total) => total.currency == base)) {
      return base;
    }
    if (totals.isNotEmpty) return totals.first.currency;
    return base != null && base.isNotEmpty ? base : 'SAR';
  }

  /// All confirmed in-period transactions for the appendix, newest first.
  ///
  /// Mirrors the totals' scope so appendix rows net to the displayed totals
  /// (MALI-063n): half-open `[from, to)`, and — in the combined (all-accounts)
  /// view — the excluded-from-totals account policy (null-account rows stay in).
  /// Result of building the appendix: the rows (≤ [_appendixMaxRows]) OR an
  /// explicit omission when the period exceeds that bound — NEVER a silent
  /// truncation that would make the report look complete while dropping rows.
  Future<({List<TransactionEntity> rows, bool omitted})> _appendixFor(
      DateRange range, String? accountId) async {
    final fromU = range.from.toUtc();
    final toU = range.to.toUtc();
    // MALI-030 — page the appendix via KEYSET (occurred_at DESC, id DESC): each DB
    // read retains at most [_appendixPageSize] rows. If the period has MORE than
    // [_appendixMaxRows] confirmed transactions, the detailed appendix is OMITTED
    // (empty + omitted:true) so the caller can state so truthfully — the summary
    // and aggregates stay complete. Same confirmed / half-open / excluded-account
    // / ownership policy the totals use.
    final rows = <TransactionEntity>[];
    DateTime? cursorOccurredAt;
    String? cursorId;
    while (true) {
      final page = await _transactions.confirmedInRangePage(
        from: fromU,
        to: toU,
        accountId: accountId,
        beforeOccurredAt: cursorOccurredAt,
        beforeId: cursorId,
        limit: _appendixPageSize,
      );
      if (page.isEmpty) break;
      rows.addAll(page);
      // Overflow: strictly MORE than the bound exists → omit truthfully. Bounded
      // accumulation (≤ cap + one page) — never the whole table.
      if (rows.length > _appendixMaxRows) {
        return (rows: const <TransactionEntity>[], omitted: true);
      }
      if (page.length < _appendixPageSize) break; // last page reached
      cursorOccurredAt = page.last.occurredAt;
      cursorId = page.last.id;
    }
    return (rows: rows, omitted: false);
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
          limit: e.budget.amountMoney,
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
          saved: g.savedMoney,
          target: g.targetMoney,
          currency: g.currency,
          progress: g.targetMoney.isZero
              ? 0.0
              : (g.savedMoney.toDouble() / g.targetMoney.toDouble())
                  .clamp(0.0, 1.0)
                  .toDouble(),
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
      if (account == null || account.currency.trim().isEmpty) {
        return const <CurrencyTotal>[];
      }
      final expense = await _transactions.expenseTotalBetween(
          from: fromU,
          to: toU,
          currency: account.currency,
          accountId: scope.accountId);
      final income = await _transactions.incomeTotalBetween(
          from: fromU,
          to: toU,
          currency: account.currency,
          accountId: scope.accountId);
      return <CurrencyTotal>[
        CurrencyTotal(
          currency: account.currency,
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
  ) async {
    final fromU = range.from.toUtc();
    final toU = range.to.toUtc();
    // Exclude flagged accounts only in the combined (all-accounts) view. A
    // single-account report still lists that account's own largest rows even
    // if it is flagged exclude_from_totals — matching the repository totals.
    // MALI-030 — bounded SQL top-N: only the top [_largestLimit] rows enter Dart
    // (was: getAll() the WHOLE table, then filter+sort in Dart). The repository
    // query applies the identical predicate — confirmed payment/withdrawal in
    // [from, to), the excluded-account policy for the all-accounts scope (the same
    // the canonical totals use) and exact account ownership (MALI-074n) otherwise.
    return _transactions.largestExpenses(
      from: fromU,
      to: toU,
      accountId: accountId,
      limit: _largestLimit,
    );
  }
}
