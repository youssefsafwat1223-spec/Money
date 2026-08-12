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
import '../../domain/repositories/transaction_repository.dart';
import '../../domain/finance/financial_period.dart';
import '../../domain/finance/money.dart';
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
  String currency,
) {
  if (categoryId == null) return null;
  for (final entry in snapshot.entries) {
    if (entry.budget.currency.toUpperCase() == currency.toUpperCase() &&
        !entry.budget.isAllExpenses &&
        entry.budget.categoryId == categoryId) {
      return entry;
    }
  }
  for (final entry in snapshot.entries) {
    if (entry.budget.currency.toUpperCase() == currency.toUpperCase() &&
        entry.budget.isAllExpenses) {
      return entry;
    }
  }
  return null;
}

/// The compact "متبقي / تجاوزت / لا توجد ميزانية" status line shown next to
/// a transaction or a monthly category group on Home.
String budgetContextText(
  BudgetProgressEntry? budget, {
  required String? categoryName,
  bool pending = false,
}) {
  if (pending) return 'عملية بانتظار التصنيف أو التأكيد';
  if (budget == null) return 'لا توجد ميزانية محددة لهذه الفئة';
  final name = categoryName ?? 'هذه الفئة';
  final currency = budget.budget.currency;
  if (budget.remaining.isNegative) {
    return 'تجاوزت ميزانية $name بـ ${_plainMoney(-budget.remaining, currency)}';
  }
  if (budget.ratio >= 0.5) {
    return 'استخدمت ${(budget.ratio * 100).round()}% من ميزانية $name';
  }
  return 'متبقي ${_plainMoney(budget.remaining, currency)} من ميزانية $name';
}

String _plainMoney(Money amount, String currency) {
  final suffix = currency.trim().isEmpty
      ? ''
      : ' ${Currency.arabicLabel(currency.toUpperCase())}';
  return '${Formatters.amount(amount.toDouble())}$suffix';
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

  // B2-C — push account + half-open today window + expense kind + (status !=
  // ignored) into SQL instead of loading & sorting the WHOLE table to keep one
  // day. Bounded to a single day, so a generous single page never truncates.
  // (`isBefore` compares instants, so the old `.toLocal()` window and this
  // UTC-stored `occurred_at` predicate are identical.)
  final todayExpenses = await txRepo.getTransactionPage(
    limit: _todayExpensesPageLimit,
    filter: TransactionPageFilter(
      accountId: accountId,
      from: startToday,
      to: endToday,
      kind: TransactionPageKind.expenses,
    ),
  );

  return RecentExpensesState(
    hasExpensesToday: todayExpenses.isNotEmpty,
    transactions: todayExpenses,
  );
});

/// A day of expenses never approaches this; a bounded single page replaces the
/// old full-table load.
const int _todayExpensesPageLimit = 500;

final todayExpensesProvider =
    FutureProvider<List<TransactionEntity>>((ref) async {
  final state = await ref.watch(recentExpensesSectionProvider.future);
  return state.transactions;
});

/// One category's monthly spending group for the Home "Monthly Expenses"
/// section. [total] is the canonical net expense for the category (MALI-050n),
/// so it agrees with the budget chip beside it; [count] is the number of
/// contributing confirmed rows.
class MonthlyCategoryGroup {
  const MonthlyCategoryGroup({
    required this.categoryId,
    required this.total,
    required this.count,
    this.budget,
  });

  final String? categoryId;
  final Money total;
  final int count;
  final BudgetProgressEntry? budget;
}

/// Current calendar month's category spending for the Home "Monthly Expenses"
/// section, highest net spend first.
///
/// MALI-050n — the totals come from the ONE canonical aggregate
/// ([TransactionRepository.categoryBreakdown]) rather than a bespoke Dart fold,
/// so refund netting, the confirmed-only status contract, the excluded-account
/// policy, the half-open month window and the account/currency scope all match
/// the budget chip attached to each group (via [matchBudgetForCategory], which
/// reuses the same canonical budget math). A category amount and its adjacent
/// budget metric therefore cannot disagree for the same scope. Uncategorized
/// rows carry no category identity to rank or budget and — consistent with the
/// Reports category ranking, which uses the same aggregate — are not shown as a
/// group. The calculation is set-based Drift/local-first and works offline.
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
  final activeAccount = selectedAccount ?? defaultAccount;
  final accountId = activeAccount?.id;
  final String currency =
      activeAccount?.currency ?? (await ref.watch(baseCurrencyProvider.future));

  // Canonical half-open month [startOfMonth, startOfNextMonth) — one definition
  // shared across the app (MALI-028/062n), Saturday-week irrelevant here.
  final period = FinancialPeriod.month(DateTime.now());

  final breakdown = await txRepo.categoryBreakdown(
    from: period.from,
    to: period.to,
    currency: currency,
    accountId: accountId,
  );

  final budgetsView = await ref.watch(budgetsViewProvider.future);
  // categoryBreakdown already orders by net total descending — keep that
  // ranking (matches Reports/dashboard donut).
  return breakdown
      .map(
        (row) => MonthlyCategoryGroup(
          categoryId: row.categoryId,
          total: row.total,
          count: row.count,
          budget: matchBudgetForCategory(
            budgetsView.snapshot,
            row.categoryId,
            currency,
          ),
        ),
      )
      .toList();
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
  // MALI-026 (B8-3 §16): this is a LIST of goals (each card shows its own
  // currency), NOT a folded total — so it is NOT scoped to one currency; every
  // active goal is shown regardless of currency (no cross-currency math occurs).
  final goals = (await ref.watch(goalsListProvider.future)).toList();
  double ratio(GoalEntity g) => g.targetMoney.isZero
      ? 0
      : (g.savedMoney.toDouble() / g.targetMoney.toDouble())
          .clamp(0, 1)
          .toDouble();
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
