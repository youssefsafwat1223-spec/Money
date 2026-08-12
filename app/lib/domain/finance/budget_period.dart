// MALI-049n / 062n / 028 — the ONE canonical budget-period + consumption
// contract. Every budget surface (dashboard ring, budget detail, report
// snapshot, local alerts) resolves a budget's window and spend through THIS,
// so they cannot disagree and no screen filter can mutate a budget's period.
import '../entities/budget_entity.dart';
import 'money.dart';
import '../reporting/date_range.dart';
import '../repositories/transaction_repository.dart';
import 'financial_period.dart';

FinancialPeriodKind _kindFor(BudgetPeriod period) => switch (period) {
      BudgetPeriod.daily => FinancialPeriodKind.day,
      BudgetPeriod.weekly => FinancialPeriodKind.week,
      BudgetPeriod.monthly => FinancialPeriodKind.month,
      BudgetPeriod.yearly => FinancialPeriodKind.year,
    };

/// The budget's CURRENT period as a genuine half-open `[from, to)` window in the
/// business timezone (Saturday-anchored week), derived from [now] — a recurring
/// budget always resolves to the live period regardless of any screen filter.
/// The upper bound is the start of the next period, never an epsilon-adjusted
/// last instant (MALI-028 boundary rule).
DateRange resolveBudgetPeriod(BudgetEntity budget, DateTime now) =>
    FinancialPeriod.of(_kindFor(budget.period), now);

/// The genuine half-open window for the period containing [start] (used for
/// rollover / historical windows), Saturday-anchored week, no epsilon end.
DateRange budgetPeriodContaining(BudgetPeriod period, DateTime start) =>
    FinancialPeriod.of(_kindFor(period), start);

String budgetPeriodLabel(BudgetPeriod period) => switch (period) {
      BudgetPeriod.daily => 'اليوم',
      BudgetPeriod.weekly => 'هذا الأسبوع',
      BudgetPeriod.monthly => 'هذا الشهر',
      BudgetPeriod.yearly => 'هذا العام',
    };

/// Canonical budget consumption over [period]. All-expenses budgets net across
/// every category; category budgets scope to their category. Both route through
/// the ONE canonical aggregate (refund netting, confirmed-only status,
/// excluded-account policy). A budget with its own [BudgetEntity.accountId]
/// stays account-scoped; a global budget falls back to [fallbackAccountId] (the
/// surface's active account) so the dashboard ring and budget detail agree for
/// the same scope. Set-based Drift aggregation — never a Dart-side fold.
Future<Money> budgetSpent(
  TransactionRepository repo,
  BudgetEntity budget,
  DateRange period, {
  String? fallbackAccountId,
}) {
  final accountId = budget.accountId ?? fallbackAccountId;
  return budget.isAllExpenses
      ? repo.expenseTotalBetween(
          from: period.from,
          to: period.to,
          currency: budget.currency,
          accountId: accountId,
        )
      : repo.categoryExpenseTotalBetween(
          categoryId: budget.categoryId,
          from: period.from,
          to: period.to,
          currency: budget.currency,
          accountId: accountId,
        );
}
