import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../domain/entities/account_entity.dart';
import '../../domain/entities/budget_entity.dart';
import '../../domain/entities/engagement_entities.dart';
import '../../domain/entities/goal_entity.dart';
import '../../domain/entities/transaction_entity.dart';
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
  ref.watch(dbRevisionProvider);
  final budgetRepo = ref.watch(budgetRepositoryProvider);
  final txRepo = ref.watch(transactionRepositoryProvider);
  final accountRepo = ref.watch(accountRepositoryProvider);
  final catalog = await ref.watch(categoryCatalogProvider.future);
  final range = ref.watch(transactionsDateRangeProvider);
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
    final scopedAccountId = budget.accountId ?? fallbackAccountId;
    final spent = budget.isAllExpenses
        ? await txRepo.expenseTotalBetween(
            from: from,
            to: to,
            accountId: scopedAccountId,
          )
        : await txRepo.categoryExpenseTotalBetween(
            categoryId: budget.categoryId,
            from: from,
            to: to,
            accountId: scopedAccountId,
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
    final entries = <BudgetProgressEntry>[];
    for (final budget in source) {
      entries.add(await buildEntry(
        budget,
        from: range.from,
        to: range.to,
        fallbackAccountId: fallbackAccountId,
      ));
    }
    entries.sort((a, b) => b.ratio.compareTo(a.ratio));
    return BudgetProgressSnapshot(entries: entries, alerts: const []);
  }

  final snapshot = await buildSnapshot(budgets, fallbackAccountId: accountId);
  final allTransactions = await txRepo.getAll();
  final historyEntries = <BudgetHistoryEntry>[];
  final now = DateTime.now();
  final historyFrom = _dateOnly(range.from);
  final historyTo = range.to.isAfter(now) ? now : range.to;
  for (final budget in allActiveBudgets) {
    for (final period in _budgetPeriodsInRange(
      budget,
      from: historyFrom,
      to: historyTo,
      now: now,
    )) {
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
            allTransactions,
            budget: budget,
            from: period.start,
            to: period.end,
          ),
        ),
      );
    }
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
  final accounts = await accountRepo.getAll();
  return BudgetsView(
    snapshot: snapshot,
    historyEntries: historyEntries,
    catalog: catalog,
    goals: goals,
    accounts: accounts,
  );
});

List<TransactionEntity> _budgetTransactionsForPeriod(
  List<TransactionEntity> transactions, {
  required BudgetEntity budget,
  required DateTime from,
  required DateTime to,
}) {
  final result = transactions.where((tx) {
    if (tx.status != TransactionStatus.confirmed) return false;
    final isExpense = tx.type == TransactionTypeEntity.payment ||
        tx.type == TransactionTypeEntity.withdrawal;
    if (!isExpense) return false;
    if (tx.occurredAt.isBefore(from) || tx.occurredAt.isAfter(to)) {
      return false;
    }
    if (budget.accountId != null && tx.accountId != budget.accountId) {
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
  var start = anchor;
  final weeksSinceAnchor = from.difference(anchor).inDays ~/ 7;
  if (weeksSinceAnchor > 0) {
    start = anchor.add(Duration(days: (weeksSinceAnchor - 1) * 7));
  }
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
  var index = _monthDiff(anchor, from) - 1;
  if (index < 0) index = 0;
  final periods = <_BudgetPeriodWindow>[];
  while (true) {
    final start = _addMonthsClamped(anchor, index);
    if (start.isAfter(to)) break;
    final rawEnd = _addMonthsClamped(anchor, index + 1)
        .subtract(const Duration(milliseconds: 1));
    if (!rawEnd.isBefore(from)) {
      periods.add(_periodWindow(start, rawEnd, now));
    }
    index += 1;
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
    end: isCurrent ? now : rawEnd,
    isCurrent: isCurrent,
  );
}

DateTime _dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);

DateTime _endOfDay(DateTime value) =>
    DateTime(value.year, value.month, value.day, 23, 59, 59, 999);

int _monthDiff(DateTime from, DateTime to) =>
    (to.year - from.year) * 12 + (to.month - from.month);

DateTime _addMonthsClamped(DateTime anchor, int months) {
  final totalMonths = anchor.month - 1 + months;
  final year = anchor.year + totalMonths ~/ 12;
  final month = totalMonths % 12 + 1;
  final day = anchor.day.clamp(1, _daysInMonth(year, month));
  return DateTime(year, month, day);
}

int _daysInMonth(int year, int month) => DateTime(year, month + 1, 0).day;

final budgetsPageTabProvider = StateProvider<int>((ref) => 0);

final budgetByIdProvider =
    FutureProvider.family<BudgetEntity?, String>((ref, id) async {
  ref.watch(budgetsViewProvider);
  return ref.watch(budgetRepositoryProvider).getById(id);
});

void refreshBudgets(WidgetRef ref) {
  ref.invalidate(budgetsViewProvider);
}
