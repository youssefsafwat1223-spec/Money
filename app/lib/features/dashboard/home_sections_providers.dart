import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../core/utils/currency.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/riyadh_time.dart';
import '../../domain/entities/bill_entity.dart';
import '../../domain/entities/engagement_entities.dart';
import '../../domain/entities/goal_entity.dart';
import '../../domain/entities/plan_entity.dart';
import '../../domain/entities/transaction_entity.dart';
import '../budgets/budgets_providers.dart';
import '../goals/goals_providers.dart';
import '../plans/plans_providers.dart';
import '../subscriptions/subscriptions_providers.dart';

/// Finds the best-matching budget for a transaction/category — an exact
/// category budget takes priority over an "all expenses" catch-all budget.
/// Reuses [budgetsViewProvider]'s already-computed spent/remaining/ratio
/// (correct per-period math) rather than recalculating budget state here.
BudgetProgressEntry? matchBudgetForCategory(
  BudgetProgressSnapshot snapshot,
  String? categoryId,
) {
  if (categoryId == null) return null;
  for (final entry in snapshot.entries) {
    if (!entry.budget.isAllExpenses && entry.budget.categoryId == categoryId) {
      return entry;
    }
  }
  for (final entry in snapshot.entries) {
    if (entry.budget.isAllExpenses) return entry;
  }
  return null;
}

/// The compact "متبقي / تجاوزت / لا توجد ميزانية" status line shown next to
/// a transaction or a monthly category group on Home.
String budgetContextText(
  BudgetProgressEntry? budget, {
  required String? categoryName,
  required String currency,
  bool pending = false,
}) {
  if (pending) return 'عملية بانتظار التصنيف أو التأكيد';
  if (budget == null) return 'لا توجد ميزانية محددة لهذه الفئة';
  final name = categoryName ?? 'هذه الفئة';
  if (budget.remaining < 0) {
    return 'تجاوزت ميزانية $name بـ ${_plainMoney(budget.remaining.abs(), currency)}';
  }
  if (budget.ratio >= 0.5) {
    return 'استخدمت ${(budget.ratio * 100).round()}% من ميزانية $name';
  }
  return 'متبقي ${_plainMoney(budget.remaining, currency)} من ميزانية $name';
}

String _plainMoney(double amount, String currency) {
  final suffix = currency.trim().isEmpty
      ? ''
      : ' ${Currency.arabicLabel(currency.toUpperCase())}';
  return '${Formatters.amount(amount)}$suffix';
}

class RecentExpensesState {
  const RecentExpensesState({
    required this.hasExpensesToday,
    required this.transactions,
  });

  final bool hasExpensesToday;
  final List<TransactionEntity> transactions;
}

/// Recent expense transactions for the Home section, newest first.
/// Indicates whether there are any expenses recorded today.
final recentExpensesSectionProvider =
    FutureProvider<RecentExpensesState>((ref) async {
  ref.watch(dbRevisionProvider);
  final txRepo = ref.watch(transactionRepositoryProvider);
  final accountRepo = ref.watch(accountRepositoryProvider);
  final selectedAccountId = ref.watch(activeAccountIdProvider);
  final selectedAccount = selectedAccountId == null
      ? null
      : await accountRepo.getById(selectedAccountId);
  final defaultAccount = await accountRepo.getDefault();
  final accountId = (selectedAccount ?? defaultAccount)?.id;

  final now = DateTime.now();
  final startToday = RiyadhTime.startOfDay(now);
  final endToday = RiyadhTime.endOfDay(now);

  final all = await txRepo.getAll();
  final validExpenses = all.where((tx) {
    if (tx.status == TransactionStatus.ignored) return false;
    final isExpense = tx.type == TransactionTypeEntity.payment ||
        tx.type == TransactionTypeEntity.withdrawal;
    if (!isExpense) return false;
    if (accountId != null && tx.accountId != accountId) return false;
    return true;
  }).toList();
  validExpenses.sort((a, b) => b.occurredAt.compareTo(a.occurredAt));

  final todayExpenses = validExpenses.where((tx) {
    final occurredAt = tx.occurredAt.toLocal();
    return !occurredAt.isBefore(startToday) && occurredAt.isBefore(endToday);
  }).toList();

  return RecentExpensesState(
    hasExpensesToday: todayExpenses.isNotEmpty,
    transactions: todayExpenses,
  );
});

final todayExpensesProvider =
    FutureProvider<List<TransactionEntity>>((ref) async {
  final state = await ref.watch(recentExpensesSectionProvider.future);
  return state.transactions;
});

/// One category's monthly spending group for the Home "Monthly Expenses"
/// section — a total plus a handful of recent transactions, not a chart.
class MonthlyCategoryGroup {
  const MonthlyCategoryGroup({
    required this.categoryId,
    required this.total,
    required this.transactions,
    this.budget,
  });

  final String? categoryId;
  final double total;
  final List<TransactionEntity> transactions;
  final BudgetProgressEntry? budget;
}

/// Current calendar month's confirmed expenses (local device time), grouped
/// by category and ordered by highest spend first — the same convention
/// `topCategories`/Reports already use for category rankings elsewhere in
/// the app, so Home stays consistent with Reports rather than introducing a
/// second ordering convention.
final monthlyExpenseGroupsProvider =
    FutureProvider<List<MonthlyCategoryGroup>>((ref) async {
  ref.watch(dbRevisionProvider);
  final txRepo = ref.watch(transactionRepositoryProvider);
  final accountRepo = ref.watch(accountRepositoryProvider);
  final selectedAccountId = ref.watch(activeAccountIdProvider);
  final selectedAccount = selectedAccountId == null
      ? null
      : await accountRepo.getById(selectedAccountId);
  final defaultAccount = await accountRepo.getDefault();
  final accountId = (selectedAccount ?? defaultAccount)?.id;

  final now = DateTime.now();
  final start = DateTime(now.year, now.month, 1);
  final end = DateTime(now.year, now.month + 1, 1)
      .subtract(const Duration(milliseconds: 1));

  final all = await txRepo.getAll();
  final monthly = all.where((tx) {
    if (tx.status != TransactionStatus.confirmed) return false;
    final isExpense = tx.type == TransactionTypeEntity.payment ||
        tx.type == TransactionTypeEntity.withdrawal;
    if (!isExpense) return false;
    if (tx.occurredAt.isBefore(start) || tx.occurredAt.isAfter(end)) {
      return false;
    }
    if (accountId != null && tx.accountId != accountId) return false;
    return true;
  }).toList();

  final byCategory = <String?, List<TransactionEntity>>{};
  for (final tx in monthly) {
    byCategory.putIfAbsent(tx.categoryId, () => []).add(tx);
  }

  final budgetsView = await ref.watch(budgetsViewProvider.future);
  final groups = byCategory.entries.map((entry) {
    final transactions = entry.value
      ..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
    final total = transactions.fold<double>(0, (sum, tx) => sum + tx.amount);
    return MonthlyCategoryGroup(
      categoryId: entry.key,
      total: total,
      transactions: transactions,
      budget: matchBudgetForCategory(budgetsView.snapshot, entry.key),
    );
  }).toList();

  groups.sort((a, b) => b.total.compareTo(a.total));
  return groups;
});

/// Active subscriptions only, ordered by nearest upcoming charge — the
/// manually-saved bills the user tracks (`savedBillsProvider`), not the
/// auto-detected recurring-candidate heuristics `subscriptionsProvider`
/// uses, since only saved bills carry a next due date/frequency/status.
final homeSubscriptionsProvider = FutureProvider<List<BillEntity>>((ref) async {
  final bills = await ref.watch(savedBillsProvider.future);
  final active = bills
      .where((bill) =>
          bill.type == BillType.subscription &&
          bill.status == BillStatus.active)
      .toList()
    ..sort((a, b) => a.nextDueDate.compareTo(b.nextDueDate));
  return active;
});

/// Active goals prioritized for the Home preview: closest deadline first,
/// then (for goals without a deadline) highest completion percentage.
/// `GoalEntity` has no `updatedAt` field, so "recently updated" isn't used
/// as a literal sort key — deadline urgency and completion% already cover
/// the same "what needs attention" intent.
final homeGoalsProvider = FutureProvider<List<GoalEntity>>((ref) async {
  final goals = List.of(await ref.watch(goalsListProvider.future));
  double ratio(GoalEntity g) => g.targetAmount <= 0
      ? 0
      : (g.savedAmount / g.targetAmount).clamp(0, 1).toDouble();
  goals.sort((a, b) {
    final aDeadline = a.deadline;
    final bDeadline = b.deadline;
    if (aDeadline != null && bDeadline != null) {
      return aDeadline.compareTo(bDeadline);
    }
    if (aDeadline != null) return -1;
    if (bDeadline != null) return 1;
    return ratio(b).compareTo(ratio(a));
  });
  return goals;
});

/// Active (ongoing) plans for the Home preview, nearest end date first —
/// matches the "what needs my attention next" framing (a plan closer to
/// ending is more actionable than one that just started).
final homePlansProvider = FutureProvider<List<PlanProgress>>((ref) async {
  final plans = List.of(await ref.watch(plansWithSpentProvider.future));
  final active = plans.where((p) => p.plan.status == PlanStatus.active).toList()
    ..sort((a, b) => a.plan.endDate.compareTo(b.plan.endDate));
  return active;
});
