import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../core/utils/riyadh_time.dart';
import '../../domain/entities/account_entity.dart';
import '../../domain/entities/budget_entity.dart';
import '../../domain/entities/engagement_entities.dart';
import '../../domain/entities/goal_entity.dart';
import '../../domain/entities/transaction_entity.dart';
import '../../domain/finance/budget_period.dart';
import '../../domain/repositories/transaction_repository.dart';
import '../../domain/reporting/date_range.dart';
import '../common/category_catalog.dart';
import '../transactions/transactions_providers.dart';

class BudgetsView {
  const BudgetsView({
    required this.snapshot,
    required this.historyEntries,
    required this.catalog,
    required this.goals,
    required this.accounts,
  });

  final BudgetProgressSnapshot snapshot;
  final List<BudgetHistoryEntry> historyEntries;
  final CategoryCatalog catalog;
  final List<GoalEntity> goals;
  final List<AccountEntity> accounts;

  String accountName(String? id, {bool showGlobalLabel = false}) {
    if (id == null) return showGlobalLabel ? 'كل الحسابات' : '';
    final match = accounts.where((a) => a.id == id);
    return match.isEmpty ? '' : match.first.name;
  }
}

class BudgetHistoryEntry {
  const BudgetHistoryEntry({
    required this.progress,
    required this.isCurrent,
    required this.transactions,
  });

  final BudgetProgressEntry progress;
  final bool isCurrent;
  final List<TransactionEntity> transactions;

  BudgetEntity get budget => progress.budget;
}

final budgetsViewProvider = FutureProvider<BudgetsView>((ref) async {
  ref.watch(scopedRevisionProvider(kBudgetsRevisionTables));
  final budgetRepo = ref.watch(budgetRepositoryProvider);
  final txRepo = ref.watch(transactionRepositoryProvider);
  final accountRepo = ref.watch(accountRepositoryProvider);
  final catalog = await ref.watch(categoryCatalogProvider.future);
  final range =
      effectiveTransactionsRange(ref.watch(transactionsDateRangeProvider));
  final selectedAccountId = ref.watch(activeAccountIdProvider);
  final selectedAccount = selectedAccountId == null
      ? null
      : await accountRepo.getById(selectedAccountId);
  final defaultAccount = await accountRepo.getDefault();
  final activeAccount = selectedAccount ?? defaultAccount;
  final accountId = activeAccount?.id;
  final allActiveBudgets = (await budgetRepo.getAll())
      .where((budget) => budget.isActive)
      .toList(growable: false);
  final budgets = allActiveBudgets.where((budget) {
    if (!budget.isActive) return false;
    if (accountId == null) return true;
    return budget.accountId == null || budget.accountId == accountId;
  }).toList(growable: false);

  Future<BudgetProgressEntry> buildEntry(
    BudgetEntity budget, {
    required DateTime from,
    required DateTime to,
    String? fallbackAccountId,
  }) async {
    // MALI-049n: one canonical consumption contract (refund netting, confirmed-
    // only status, excluded-account policy) shared with the dashboard ring and
    // the report snapshot.
    final spent = await budgetSpent(
      txRepo,
      budget,
      DateRange(from, to),
      fallbackAccountId: fallbackAccountId,
    );
    final ratio = budget.amount == 0 ? 0.0 : spent / budget.amount;
    final health = ratio >= 1
        ? BudgetHealth.over
        : ratio >= 0.8
            ? BudgetHealth.warning
            : BudgetHealth.safe;
    return BudgetProgressEntry(
      budget: budget,
      spent: spent,
      remaining: budget.amount - spent,
      ratio: ratio,
      health: health,
      periodStart: from,
      periodEnd: to,
    );
  }

  Future<BudgetProgressSnapshot> buildSnapshot(
    List<BudgetEntity> source, {
    String? fallbackAccountId,
  }) async {
    final now = DateTime.now();
    final entries = <BudgetProgressEntry>[];
    for (final budget in source) {
      final period = _currentPeriodFor(budget, now);
      entries.add(await buildEntry(
        budget,
        from: period.from,
        to: period.to,
        fallbackAccountId: fallbackAccountId,
      ));
    }
    entries.sort((a, b) => b.ratio.compareTo(a.ratio));
    return BudgetProgressSnapshot(entries: entries);
  }

  final snapshot = await buildSnapshot(budgets, fallbackAccountId: accountId);
  final accounts = await accountRepo.getAll();
  final excludedAccountIds = <String>{
    for (final account in accounts)
      if (account.excludeFromTotals) account.id,
  };
  final now = DateTime.now();
  final historyFrom = _dateOnly(range.from);
  final historyTo = range.to.isAfter(now) ? now : range.to;

  // B2-C — bound the line-item transaction load to the UNION of the actual
  // budget-period windows instead of the whole ledger (`getAll()`). Pass 1
  // computes every (budget, period) window and the min/max instants they span
  // (a week/month/year period can start before `historyFrom` and end after it),
  // then a range-scoped keyset drain loads ONLY those transactions. The
  // per-period Dart filter (`_budgetTransactionsForPeriod`) is UNCHANGED — same
  // canonical confirmed/refund/status/scope/exclusion semantics — and every
  // period window ⊆ [loadFrom, loadTo], so the result is identical to the old
  // full-ledger fold while a 10k ledger with a small period never materialises.
  final plannedPeriods =
      <({BudgetEntity budget, _BudgetPeriodWindow period})>[];
  DateTime? loadFrom;
  DateTime? loadTo;
  for (final budget in allActiveBudgets) {
    for (final period in _budgetPeriodsInRange(
      budget,
      from: historyFrom,
      to: historyTo,
      now: now,
    )) {
      plannedPeriods.add((budget: budget, period: period));
      if (loadFrom == null || period.start.isBefore(loadFrom)) {
        loadFrom = period.start;
      }
      if (loadTo == null || period.end.isAfter(loadTo)) {
        loadTo = period.end;
      }
    }
  }
  final rangeTransactions = (loadFrom == null || loadTo == null)
      ? const <TransactionEntity>[]
      : await _drainTransactionsInRange(
          txRepo,
          from: loadFrom,
          // +1ms so a row exactly at the max period-end is loaded; the
          // per-period `< end` filter still applies the exact half-open cut.
          to: loadTo.add(const Duration(milliseconds: 1)),
        );

  final historyEntries = <BudgetHistoryEntry>[];
  for (final planned in plannedPeriods) {
    final budget = planned.budget;
    final period = planned.period;
    final entry = await buildEntry(
      budget,
      from: period.start,
      to: period.end,
    );
    historyEntries.add(
      BudgetHistoryEntry(
        progress: entry,
        isCurrent: period.isCurrent,
        transactions: _budgetTransactionsForPeriod(
          rangeTransactions,
          budget: budget,
          from: period.start,
          to: period.end,
          excludedAccountIds: excludedAccountIds,
        ),
      ),
    );
  }
  historyEntries.sort((a, b) {
    final dateCompare =
        b.progress.periodStart.compareTo(a.progress.periodStart);
    if (dateCompare != 0) return dateCompare;
    return b.progress.ratio.compareTo(a.progress.ratio);
  });
  final goals = (await ref.watch(goalRepositoryProvider).getAll())
      .where((goal) =>
          goal.status == 'active' &&
          (accountId == null || goal.accountId == accountId))
      .toList(growable: false);
  return BudgetsView(
    snapshot: snapshot,
    historyEntries: historyEntries,
    catalog: catalog,
    goals: goals,
    accounts: accounts,
  );
});

/// B2-C — drains all non-ignored transactions in the half-open `[from, to)`
/// window via bounded keyset pages (never `getAll()`). The caller's per-period
/// filter re-applies the exact confirmed/type/scope predicate, so this may
/// safely over-fetch pending/other rows within the window; it must never load
/// unrelated history outside it.
Future<List<TransactionEntity>> _drainTransactionsInRange(
  TransactionRepository repo, {
  required DateTime from,
  required DateTime to,
}) async {
  const pageSize = 500;
  final out = <TransactionEntity>[];
  TransactionPageCursor? cursor;
  while (true) {
    final page = await repo.getTransactionPage(
      limit: pageSize,
      after: cursor,
      filter: TransactionPageFilter(from: from, to: to),
    );
    out.addAll(page);
    if (page.length < pageSize) break;
    final last = page.last;
    cursor = TransactionPageCursor(occurredAt: last.occurredAt, id: last.id);
  }
  return out;
}

/// MALI-062n tail — the per-period budget transaction list must represent the
/// SAME metric as its net total. It therefore mirrors the canonical
/// consumption contract exactly: confirmed-only, the net-expense types
/// (payment/withdrawal ADD, refund SUBTRACTS — refunds are included so the
/// list's signed sum equals the net total, never hidden), a half-open
/// `[from, to)` window, the budget's account/category scope, and — for a global
/// budget — the combined-totals excluded-account policy (null-account rows stay
/// in). The signed sum of this list equals `budgetSpent` for the same scope.
List<TransactionEntity> _budgetTransactionsForPeriod(
  List<TransactionEntity> transactions, {
  required BudgetEntity budget,
  required DateTime from,
  required DateTime to,
  required Set<String> excludedAccountIds,
}) {
  final result = transactions.where((tx) {
    if (tx.status != TransactionStatus.confirmed) return false;
    final isNetExpense = tx.type == TransactionTypeEntity.payment ||
        tx.type == TransactionTypeEntity.withdrawal ||
        tx.type == TransactionTypeEntity.refund;
    if (!isNetExpense) return false;
    if (tx.occurredAt.isBefore(from) || !tx.occurredAt.isBefore(to)) {
      return false;
    }
    if (budget.accountId != null) {
      if (tx.accountId != budget.accountId) return false;
    } else if (tx.accountId != null && excludedAccountIds.contains(tx.accountId)) {
      return false;
    }
    if (!budget.isAllExpenses && tx.categoryId != budget.categoryId) {
      return false;
    }
    return true;
  }).toList(growable: false);
  result.sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
  return result;
}

/// Signed contribution of a budget-history row to the net total: refund
/// subtracts, payment/withdrawal add. Kept next to [_budgetTransactionsForPeriod]
/// so the list and its total cannot drift apart.
/// Transitional presentation projection: the public history API still returns
/// double and may be exercised with mixed test/account currencies.
double budgetHistoryRowSigned(TransactionEntity tx) =>
    tx.type == TransactionTypeEntity.refund ? -tx.amount : tx.amount;

class _BudgetPeriodWindow {
  const _BudgetPeriodWindow({
    required this.start,
    required this.end,
    required this.isCurrent,
  });

  final DateTime start;
  final DateTime end;
  final bool isCurrent;
}

List<_BudgetPeriodWindow> _budgetPeriodsInRange(
  BudgetEntity budget, {
  required DateTime from,
  required DateTime to,
  required DateTime now,
}) {
  if (to.isBefore(from)) return const [];
  final anchor = _dateOnly(budget.startDate);
  if (to.isBefore(anchor)) return const [];
  return switch (budget.period) {
    BudgetPeriod.daily => _dailyPeriods(anchor, from, to, now),
    BudgetPeriod.weekly => _weeklyPeriods(anchor, from, to, now),
    BudgetPeriod.monthly => _monthlyPeriods(anchor, from, to, now),
    BudgetPeriod.yearly => _yearlyPeriods(from, to, now),
  };
}

List<_BudgetPeriodWindow> _dailyPeriods(
  DateTime anchor,
  DateTime from,
  DateTime to,
  DateTime now,
) {
  var start = anchor;
  final daysSinceAnchor = from.difference(anchor).inDays;
  if (daysSinceAnchor > 0) {
    start = anchor.add(Duration(days: daysSinceAnchor - 1));
  }
  final periods = <_BudgetPeriodWindow>[];
  while (!start.isAfter(to)) {
    final rawEnd = _endOfDay(start);
    if (!rawEnd.isBefore(from)) {
      periods.add(_periodWindow(start, rawEnd, now));
    }
    start = start.add(const Duration(days: 1));
  }
  return periods;
}

List<_BudgetPeriodWindow> _weeklyPeriods(
  DateTime anchor,
  DateTime from,
  DateTime to,
  DateTime now,
) {
  // MALI-049n/062n: history weeks are Saturday-anchored (the canonical week),
  // matching the current-period resolver — not the budget's arbitrary
  // creation-day anchor, which made the current-week ring and history disagree.
  var start = RiyadhTime.startOfWeek(from);
  final periods = <_BudgetPeriodWindow>[];
  while (!start.isAfter(to)) {
    final rawEnd = start
        .add(const Duration(days: 7))
        .subtract(const Duration(milliseconds: 1));
    if (!rawEnd.isBefore(from)) {
      periods.add(_periodWindow(start, rawEnd, now));
    }
    start = start.add(const Duration(days: 7));
  }
  return periods;
}

List<_BudgetPeriodWindow> _monthlyPeriods(
  DateTime anchor,
  DateTime from,
  DateTime to,
  DateTime now,
) {
  // Always use calendar months (1st → last day), ignoring anchor.day.
  var current = DateTime(from.year, from.month, 1);
  final periods = <_BudgetPeriodWindow>[];
  while (!current.isAfter(to)) {
    final start = current;
    final rawEnd = DateTime(current.year, current.month + 1, 1)
        .subtract(const Duration(milliseconds: 1));
    if (!rawEnd.isBefore(from)) {
      periods.add(_periodWindow(start, rawEnd, now));
    }
    current = DateTime(current.year, current.month + 1, 1);
  }
  return periods;
}

List<_BudgetPeriodWindow> _yearlyPeriods(
  DateTime from,
  DateTime to,
  DateTime now,
) {
  final periods = <_BudgetPeriodWindow>[];
  for (var year = from.year; year <= to.year; year++) {
    final start = DateTime(year, 1, 1);
    final rawEnd =
        DateTime(year + 1, 1, 1).subtract(const Duration(milliseconds: 1));
    if (!rawEnd.isBefore(from) && !start.isAfter(to)) {
      periods.add(_periodWindow(start, rawEnd, now));
    }
  }
  return periods;
}

_BudgetPeriodWindow _periodWindow(
  DateTime start,
  DateTime rawEnd,
  DateTime now,
) {
  final isCurrent = !now.isBefore(start) && !now.isAfter(rawEnd);
  return _BudgetPeriodWindow(
    start: start,
    end: rawEnd, // Always show the full period range, not clamped to today
    isCurrent: isCurrent,
  );
}

DateTime _dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);

DateTime _endOfDay(DateTime value) =>
    DateTime(value.year, value.month, value.day, 23, 59, 59, 999);

/// Returns the start/end of the budget's CURRENT active period.
/// Monthly → 1st of month → last day of month (calendar month).
/// Yearly  → Jan 1 → Dec 31 (calendar year).
/// Weekly  → rolling window from startDate anchor.
/// Daily   → today only.
// MALI-049n/028: the budget's CURRENT period via the ONE canonical resolver —
// genuine half-open `[from, to)`, Saturday-anchored week, no epsilon end.
({DateTime from, DateTime to}) _currentPeriodFor(
    BudgetEntity budget, DateTime now) {
  final range = resolveBudgetPeriod(budget, now);
  return (from: range.from, to: range.to);
}

final budgetsPageTabProvider = StateProvider<int>((ref) => 0);

/// null = show all periods in the history tab
final budgetsHistoryPeriodFilterProvider =
    StateProvider<BudgetPeriod?>((ref) => null);

final budgetByIdProvider =
    FutureProvider.family<BudgetEntity?, String>((ref, id) async {
  ref.watch(budgetsViewProvider);
  return ref.watch(budgetRepositoryProvider).getById(id);
});

void refreshBudgets(WidgetRef ref) {
  ref.invalidate(budgetsViewProvider);
}
