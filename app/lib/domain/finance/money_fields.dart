/// MALI-026 (Phase-8 B8-1.5) — the persisted money-field REGISTRY and the
/// Strategy-A activation invariant surface.
///
/// This is the single, structured source of truth for every persisted money
/// column, its currency authority, and its nullability. A completeness guard
/// test (money_fields_completeness_test.dart) enumerates the LIVE Drift schema's
/// REAL columns and asserts each is classified here (money) or in
/// [kNonMoneyRealColumns] — so a NEW money column or writer cannot be added
/// without fixed-precision handling. It is schema-derived, not a source grep.
library;

/// How the canonical currency for a money field is resolved (Decision 3).
enum CurrencyAuthority {
  /// The money row carries its own `currency` column.
  sameRowCurrency,

  /// A transaction's foreign leg — currency is the row's `foreign_currency`,
  /// which MUST be non-null when the amount is non-null.
  sameRowForeignCurrency,

  /// Budgets/goals/goal_contributions: base currency (user_settings.currency)
  /// is the DOMAIN CONTRACT (displayed via baseCurrencyProvider), not a fallback.
  baseCurrency,
}

class MoneyField {
  const MoneyField(this.table, this.column, this.authority, {this.nullable = false});
  final String table;
  final String column;
  final CurrencyAuthority authority;
  final bool nullable;
}

/// Every persisted money column in Drift schema v29.
const List<MoneyField> kMoneyFields = [
  MoneyField('transactions', 'amount', CurrencyAuthority.sameRowCurrency),
  MoneyField('transactions', 'balance_after', CurrencyAuthority.sameRowCurrency,
      nullable: true),
  MoneyField('transactions', 'foreign_amount',
      CurrencyAuthority.sameRowForeignCurrency, nullable: true),
  MoneyField('accounts', 'initial_balance', CurrencyAuthority.sameRowCurrency,
      nullable: true),
  MoneyField('accounts', 'current_balance', CurrencyAuthority.sameRowCurrency,
      nullable: true),
  MoneyField('accounts', 'credit_limit', CurrencyAuthority.sameRowCurrency,
      nullable: true),
  MoneyField('accounts', 'available_credit', CurrencyAuthority.sameRowCurrency,
      nullable: true),
  MoneyField('budgets', 'amount', CurrencyAuthority.baseCurrency),
  MoneyField('budgets', 'last_notified_spent_amount',
      CurrencyAuthority.baseCurrency),
  MoneyField('goals', 'target_amount', CurrencyAuthority.baseCurrency),
  MoneyField('goals', 'saved_amount', CurrencyAuthority.baseCurrency),
  MoneyField('goals', 'last_notified_saved_amount',
      CurrencyAuthority.baseCurrency),
  MoneyField('goals', 'auto_save_amount', CurrencyAuthority.baseCurrency,
      nullable: true),
  MoneyField('goal_contributions', 'amount', CurrencyAuthority.baseCurrency),
  MoneyField('subscriptions', 'amount', CurrencyAuthority.sameRowCurrency),
  MoneyField('subscriptions', 'manual_paid_amount',
      CurrencyAuthority.sameRowCurrency, nullable: true),
  MoneyField('subscriptions', 'total_purchase_amount',
      CurrencyAuthority.sameRowCurrency, nullable: true),
  MoneyField('bill_payments', 'amount', CurrencyAuthority.sameRowCurrency),
  MoneyField('plans', 'budget_amount', CurrencyAuthority.sameRowCurrency),
  MoneyField('suspected_duplicates', 'amount', CurrencyAuthority.sameRowCurrency),
];

/// REAL columns that are explicitly NOT money (ratios / rates / ML confidence)
/// and therefore stay `double` — never converted to minor units. Keyed by the
/// (distinctive) column name.
const Set<String> kNonMoneyRealColumns = {
  'confidence',
  'parse_confidence',
  'progress',
  'interest_rate', // an installment RATE (display-only percentage), not money
  'ratio',
};

/// Fast (table, column) → MoneyField lookup.
final Map<String, MoneyField> kMoneyFieldByKey = {
  for (final f in kMoneyFields) '${f.table}.${f.column}': f,
};
