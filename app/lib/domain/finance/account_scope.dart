import '../entities/budget_entity.dart';

/// R-2 / OD-08 — the single definition of "which account am I looking at, and
/// what belongs to it".
///
/// ## Why this exists
/// Every screen re-derived its own scope predicate, and they disagreed. Two
/// surfaces showing the same budget produced different numbers:
///
/// * Dashboard (`dashboard_providers.dart`) — with an account selected,
///   `budget.accountId == accountId`, which **excludes global budgets**, plus a
///   currency filter.
/// * Budgets screen (`budgets_providers.dart`) —
///   `budget.accountId == null || budget.accountId == accountId`, which
///   **includes** them, and no currency filter.
///
/// Dashboard's `accountId` is virtually never null (it falls back to the default
/// account, then the first account), so in practice the Home ring and the
/// Budgets screen were computing over different budget sets. That is F-026, and
/// F-019 is the same disease inside one screen: the Budgets *history* loop
/// iterated the unfiltered list while the tab above it was scoped.
///
/// ## The rule (OD-08)
/// * A specific account selected → account-scoped: budgets belonging to that
///   account, **plus global budgets**, because a global budget genuinely applies
///   to that account too. Hiding it makes the ring under-count.
/// * "All accounts" → everything.
///
/// Screens consume this instead of inventing their own semantics. A shared
/// helper is not sufficient on its own — the previous divergence happened
/// *around* a shared `budgetSpent`, because each caller filtered its INPUT
/// differently. Scope is therefore part of the contract, not left to the caller.
class AccountScope {
  const AccountScope._(this.accountId);

  /// Scoped to one account. Global (account-less) rows still apply.
  const AccountScope.account(String accountId) : this._(accountId);

  /// Every account.
  const AccountScope.all() : this._(null);

  /// `null` means "all accounts".
  final String? accountId;

  bool get isAll => accountId == null;

  /// Whether [budgetAccountId] falls in scope.
  ///
  /// A global budget (`null`) is in scope for EVERY account — that is the
  /// OD-08 decision, and the half the dashboard was getting wrong.
  bool includesBudget(String? budgetAccountId) =>
      isAll || budgetAccountId == null || budgetAccountId == accountId;

  /// Whether a transaction/row owned by [rowAccountId] falls in scope.
  ///
  /// Deliberately STRICTER than [includesBudget]: a transaction belongs to
  /// exactly one account, so a null-account row is not "everyone's" — it is
  /// unassigned, and counting it under every account would double-count money.
  bool includesRow(String? rowAccountId) =>
      isAll || (rowAccountId != null && rowAccountId == accountId);

  /// Convenience for the common `selected ?? default` derivation.
  static AccountScope resolve(String? selectedAccountId) =>
      selectedAccountId == null
          ? const AccountScope.all()
          : AccountScope.account(selectedAccountId);

  @override
  String toString() => isAll ? 'AccountScope.all' : 'AccountScope($accountId)';
}

/// Filters [budgets] to [scope], preserving order.
///
/// Callers must not re-filter afterwards: doing so is exactly how the two
/// surfaces drifted apart.
List<BudgetEntity> budgetsInScope(
  Iterable<BudgetEntity> budgets,
  AccountScope scope, {
  bool activeOnly = true,
}) =>
    budgets
        .where((b) => !activeOnly || b.isActive)
        .where((b) => scope.includesBudget(b.accountId))
        .toList(growable: false);
