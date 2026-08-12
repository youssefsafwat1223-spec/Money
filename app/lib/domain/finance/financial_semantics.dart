/// MALI-047n…050n / 063n / 064n / 074n / 018 — the ONE canonical financial
/// semantics contract. Every surface (repositories, providers, UI, reports,
/// exports, budgets, plans, bills, notifications) must derive income/expense/
/// refund/net-spend from THIS contract, never from ad-hoc arithmetic or
/// direction alone.
///
/// Net-spend convention (matches the ledger's historical repo aggregate):
///   net expense = Σ(payment) + Σ(withdrawal) − Σ(refund)
///   income      = Σ(income)
///   transfer / unknown / adjustment → excluded from net income AND net expense
///   a refund NETS against expense — it is never counted as income, and never
///   counted as both income and expense (gross-flow surfaces must opt in via
///   [grossInflow]/[grossOutflow] and label themselves).
///
/// Only `confirmed` transactions count toward spend/income metrics (see
/// [FinancialStatusTreatment]); pending values appear only on surfaces that
/// explicitly represent them.
library;

import '../entities/transaction_entity.dart';

/// How a transaction type participates in the canonical metrics.
class FinancialTypeSemantics {
  const FinancialTypeSemantics({
    required this.contributesToIncome,
    required this.contributesToExpense,
    required this.expenseSign,
    required this.affectsBudget,
    required this.affectsCategorySpending,
    required this.affectsAccountCashFlow,
    required this.grossInflow,
    required this.grossOutflow,
  });

  /// Adds to net income.
  final bool contributesToIncome;

  /// Participates in net-spend (payment/withdrawal add, refund subtracts).
  final bool contributesToExpense;

  /// The sign applied to `amount` in a net-expense sum: +1 (payment/withdrawal),
  /// −1 (refund), 0 (not an expense-metric type).
  final int expenseSign;

  /// Consumes (or, for refunds, restores) a budget.
  final bool affectsBudget;

  /// Appears in category / merchant spending breakdowns.
  final bool affectsCategorySpending;

  /// Moves cash in/out of an account (transfers move BETWEEN accounts).
  final bool affectsAccountCashFlow;

  /// Counts as gross money IN (income + refund) on a labelled gross-flow surface.
  final bool grossInflow;

  /// Counts as gross money OUT (payment + withdrawal) on a labelled gross-flow
  /// surface.
  final bool grossOutflow;

  /// Excluded from BOTH net income and net expense (transfer/unknown/adjustment).
  bool get excludedFromNetSpend =>
      !contributesToIncome && !contributesToExpense;
}

const FinancialTypeSemantics _payment = FinancialTypeSemantics(
  contributesToIncome: false,
  contributesToExpense: true,
  expenseSign: 1,
  affectsBudget: true,
  affectsCategorySpending: true,
  affectsAccountCashFlow: true,
  grossInflow: false,
  grossOutflow: true,
);

const FinancialTypeSemantics _refund = FinancialTypeSemantics(
  contributesToIncome: false, // NEVER income — it nets against expense
  contributesToExpense: true,
  expenseSign: -1,
  affectsBudget: true, // restores budget headroom
  affectsCategorySpending: true, // reduces category spend
  affectsAccountCashFlow: true,
  grossInflow: true, // gross money in (on a labelled gross surface only)
  grossOutflow: false,
);

const FinancialTypeSemantics _income = FinancialTypeSemantics(
  contributesToIncome: true,
  contributesToExpense: false,
  expenseSign: 0,
  affectsBudget: false,
  affectsCategorySpending: false,
  affectsAccountCashFlow: true,
  grossInflow: true,
  grossOutflow: false,
);

const FinancialTypeSemantics _excluded = FinancialTypeSemantics(
  contributesToIncome: false,
  contributesToExpense: false,
  expenseSign: 0,
  affectsBudget: false,
  affectsCategorySpending: false,
  affectsAccountCashFlow: false,
  grossInflow: false,
  grossOutflow: false,
);

/// A transfer moves cash between the user's own accounts — it is neither income
/// nor expense, but it DOES change per-account cash flow.
const FinancialTypeSemantics _transfer = FinancialTypeSemantics(
  contributesToIncome: false,
  contributesToExpense: false,
  expenseSign: 0,
  affectsBudget: false,
  affectsCategorySpending: false,
  affectsAccountCashFlow: true,
  grossInflow: false,
  grossOutflow: false,
);

/// The canonical per-type matrix.
const Map<TransactionTypeEntity, FinancialTypeSemantics>
    kFinancialTypeSemantics = {
  TransactionTypeEntity.payment: _payment,
  TransactionTypeEntity.withdrawal: _payment, // same net-spend semantics
  TransactionTypeEntity.refund: _refund,
  TransactionTypeEntity.income: _income,
  TransactionTypeEntity.transfer: _transfer,
  // unknown/future → excluded from every metric (never silently an expense).
  TransactionTypeEntity.unknown: _excluded,
};

FinancialTypeSemantics semanticsFor(TransactionTypeEntity type) =>
    kFinancialTypeSemantics[type] ?? _excluded;

/// How a status participates in canonical metrics.
enum FinancialStatusTreatment {
  /// Counts toward spend/income (only `confirmed`).
  counted,

  /// Represented only on surfaces that explicitly show pending values.
  pendingOnly,

  /// Never counted (ignored / deleted / tombstoned).
  excluded,
}

FinancialStatusTreatment statusTreatment(TransactionStatus status) =>
    switch (status) {
      TransactionStatus.confirmed => FinancialStatusTreatment.counted,
      TransactionStatus.pending => FinancialStatusTreatment.pendingOnly,
      TransactionStatus.ignored => FinancialStatusTreatment.excluded,
    };

/// The canonical SQL fragments — the SINGLE source of truth shared by the repo
/// aggregates and any surface that must aggregate in SQL, so no surface can
/// re-implement the semantics differently. All fragments use the local column
/// convention (`status`, `type`, `amount`) and an optional table alias prefix.
class FinancialSql {
  const FinancialSql._();

  /// The canonical spend types (net expense).
  static const List<String> netExpenseTypes = ['payment', 'withdrawal', 'refund'];

  /// Only confirmed rows count toward canonical metrics.
  static String confirmedPredicate({String alias = ''}) {
    final p = alias.isEmpty ? '' : '$alias.';
    return "${p}status = 'confirmed'";
  }

  /// `type IN (…)` for the net-expense flow.
  static String netExpenseTypePredicate({String alias = ''}) {
    final p = alias.isEmpty ? '' : '$alias.';
    return "${p}type IN ('payment', 'withdrawal', 'refund')";
  }

  /// The signed amount for a net-expense sum: refund subtracts, payment/
  /// withdrawal add, everything else contributes 0. Operates on the REAL `amount`
  /// shadow — LEGACY/display aggregates only; canonical exact totals use
  /// [netExpenseSignedAmountMinor].
  static String netExpenseSignedAmount({String alias = ''}) {
    final p = alias.isEmpty ? '' : '$alias.';
    return "CASE WHEN ${p}type = 'refund' THEN -${p}amount "
        "WHEN ${p}type IN ('payment', 'withdrawal') THEN ${p}amount "
        'ELSE 0 END';
  }

  /// MALI-026 (B8-3 §16): the net-expense signed amount over the EXACT
  /// `amount_minor` int64 column. Canonical integer aggregates SUM this; an int64
  /// overflow raises a SQLite "integer overflow" error (fail-exact — NEVER a
  /// floating fallback), so the SUM must NOT be wrapped in `CAST(... AS REAL)`.
  /// Same refund/payment/withdrawal semantics as [netExpenseSignedAmount]. Only
  /// meaningful within ONE currency (never SUM across mixed currencies).
  static String netExpenseSignedAmountMinor({String alias = ''}) {
    final p = alias.isEmpty ? '' : '$alias.';
    return "CASE WHEN ${p}type = 'refund' THEN -${p}amount_minor "
        "WHEN ${p}type IN ('payment', 'withdrawal') THEN ${p}amount_minor "
        'ELSE 0 END';
  }

  /// MALI-026 (B8-3 §16): the income-flow exact minor amount (0 for non-income).
  /// Single-currency only, integer, fail-exact on overflow (no `CAST AS REAL`).
  static String incomeSignedAmountMinor({String alias = ''}) {
    final p = alias.isEmpty ? '' : '$alias.';
    return "CASE WHEN ${p}type = 'income' THEN ${p}amount_minor ELSE 0 END";
  }

  /// The income flow.
  static String incomeTypePredicate({String alias = ''}) {
    final p = alias.isEmpty ? '' : '$alias.';
    return "${p}type = 'income'";
  }

  /// Excludes accounts flagged `exclude_from_totals` from a COMBINED aggregate
  /// (rows with a NULL account stay in). Mirrors the transaction repository's
  /// combined-totals policy so a surface that must aggregate outside that repo
  /// (e.g. an all-expenses plan) applies the same exclusion.
  static String excludedAccountExclusion({String alias = ''}) {
    final p = alias.isEmpty ? '' : '$alias.';
    return '(${p}account_id IS NULL OR NOT EXISTS ('
        'SELECT 1 FROM accounts _excl_acct WHERE _excl_acct.id = ${p}account_id '
        'AND _excl_acct.exclude_from_totals = 1))';
  }
}
