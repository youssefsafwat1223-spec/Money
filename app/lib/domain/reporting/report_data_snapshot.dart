import '../entities/account_entity.dart';
import '../entities/category_spend.dart';
import '../entities/report_models.dart';
import '../entities/transaction_entity.dart';
import '../finance/money.dart';
import 'date_range.dart';
import 'report_request.dart';

/// A display-oriented reference to an account included in a report's scope.
///
/// Deleted/unavailable accounts (soft-deleted via `deleted_at`, invisible at the
/// entity level) are represented by [unavailable] so the report can still render
/// a placeholder and keep the frozen figures consistent.
class ReportAccountRef {
  const ReportAccountRef({
    required this.id,
    required this.name,
    required this.currency,
    required this.excludeFromTotals,
    this.isAvailable = true,
  });

  factory ReportAccountRef.fromEntity(AccountEntity account) =>
      ReportAccountRef(
        id: account.id,
        name: account.name,
        currency: account.currency,
        excludeFromTotals: account.excludeFromTotals,
      );

  final String? id;
  final String name;
  final String currency;
  final bool excludeFromTotals;
  final bool isAvailable;

  /// Placeholder for a scoped account that no longer exists at generation time.
  /// The composer localises the display name from [isAvailable].
  static const ReportAccountRef unavailable = ReportAccountRef(
    id: null,
    name: '',
    currency: '',
    excludeFromTotals: false,
    isAvailable: false,
  );
}

/// Display metadata for a category (resolved at snapshot time so the pure
/// composer/renderer never query the catalog). [name] is the local Arabic name
/// (`categories.name_ar`; `name_en` lives only in `remote_categories`, so an
/// English report falls back to this or the [key]). [colorHex] is the 6-digit
/// hex from `database_seed._colorFor`.
class ReportCategoryMeta {
  const ReportCategoryMeta({
    required this.id,
    required this.key,
    required this.name,
    required this.colorHex,
  });

  final String id;
  final String key;
  final String name;
  final String colorHex;
}

/// A budget's in-period status, ready to render.
class ReportBudgetLite {
  const ReportBudgetLite({
    required this.categoryId,
    required this.spent,
    required this.limit,
    required this.ratio,
    required this.health,
  });

  /// The budget's category id (`'__all_expenses__'` for the all-expenses
  /// budget); the composer resolves the display label per-language.
  final String? categoryId;
  final Money spent;
  final Money limit;
  final double ratio;

  /// 'safe' | 'warning' | 'over' (from `BudgetHealth`).
  final String health;
}

/// A bill/subscription line, ready to render.
class ReportBillLite {
  const ReportBillLite({
    required this.name,
    required this.amount,
    required this.currency,
    required this.dueDate,
    required this.isSubscription,
    required this.status,
  });

  final String name;
  final double amount;
  final String currency;
  final DateTime? dueDate;
  final bool isSubscription;

  /// 'active' | 'paused' | 'cancelled'.
  final String status;
}

/// A savings goal's progress, ready to render.
class ReportGoalLite {
  const ReportGoalLite({
    required this.name,
    required this.saved,
    required this.target,
    required this.currency,
    required this.progress,
    required this.deadline,
  });

  final String name;
  final Money saved;
  final Money target;
  final String currency;

  /// Fraction `0..1`.
  final double progress;
  final DateTime? deadline;
}

/// The single immutable source of truth for one generated report.
///
/// Collected once by `ReportSnapshotBuilder`; every downstream layer (metrics,
/// composition, rendering) reads only from here, so figures stay internally
/// consistent even if the underlying database changes during generation. Pure
/// data — no repositories, providers, Flutter, or `pdf`.
class ReportDataSnapshot {
  const ReportDataSnapshot({
    required this.capturedAt,
    required this.request,
    required this.range,
    required this.previousRange,
    required this.accountsInScope,
    required this.currencyTotals,
    required this.previousCurrencyTotals,
    required this.totalIncome,
    required this.totalExpense,
    required this.categoryBreakdown,
    this.categoryBreakdownByCurrency = const <String, List<CategorySpend>>{},
    required this.categoryMeta,
    required this.dailyExpense,
    required this.topMerchants,
    required this.largestTransactions,
    required this.latestBalance,
    this.budgets = const <ReportBudgetLite>[],
    this.bills = const <ReportBillLite>[],
    this.goals = const <ReportGoalLite>[],
    this.appendixTransactions = const <TransactionEntity>[],
    this.appendixOmittedForSize = false,
    this.appendixRowLimit = 0,
    this.baseCurrency,
  });

  final DateTime capturedAt;
  final ReportRequest request;
  final DateRange range;
  final DateRange previousRange;
  final List<ReportAccountRef> accountsInScope;

  /// Per-currency income & expense for the period — FX-safe (currencies are
  /// never summed). All-accounts scope uses `currencyTotalsBetween`; a single
  /// account yields one entry in that account's currency.
  final List<CurrencyTotal> currencyTotals;
  final List<CurrencyTotal> previousCurrencyTotals;

  /// Raw period totals from `incomeTotalBetween` / `expenseTotalBetween`.
  ///
  /// These are scoped to the report's primary display currency. All-account
  /// reports keep every currency separately in [currencyTotals].
  final Money totalIncome;
  final Money totalExpense;

  final List<CategorySpend> categoryBreakdown;

  /// Per-currency category breakdown — `currency → categorised net expense`
  /// (MALI-063n). The FX-safe basis for the donut/slices so a multi-currency
  /// all-accounts report never mixes currencies in one chart; single-currency
  /// scopes have one entry equal to [categoryBreakdown].
  final Map<String, List<CategorySpend>> categoryBreakdownByCurrency;

  /// Category id → display metadata for every non-deleted category. Ids present
  /// in [categoryBreakdown] but absent here are deleted categories (they fold
  /// into the aggregator's "Other" remainder).
  final Map<String, ReportCategoryMeta> categoryMeta;

  final List<DailySpend> dailyExpense;
  final List<MerchantSpend> topMerchants;

  /// Confirmed expense transactions (`payment`/`withdrawal`) inside [range],
  /// largest amount first.
  final List<TransactionEntity> largestTransactions;

  /// Latest known bank balance for the scope, if any (`latestBalanceAfter`).
  final Money? latestBalance;

  /// Active budgets with in-period spend/health (empty if not collected).
  final List<ReportBudgetLite> budgets;

  /// Active bills & subscriptions (empty if not collected).
  final List<ReportBillLite> bills;

  /// Active savings goals with progress (empty if not collected).
  final List<ReportGoalLite> goals;

  /// In-period transactions for the optional appendix (only when
  /// `includeTransactionDetails` is set), newest first.
  final List<TransactionEntity> appendixTransactions;

  /// MALI-030 — true when the detailed appendix was OMITTED because the period has
  /// more than [appendixRowLimit] confirmed transactions. The report is NOT
  /// silently truncated: [appendixTransactions] is empty and the summary/aggregates
  /// remain complete and correct. Renderers must state the appendix was omitted.
  final bool appendixOmittedForSize;

  /// The detailed-appendix row bound that was exceeded (0 when not applicable).
  final int appendixRowLimit;

  /// The user's base display currency (default/active account, mirroring
  /// `baseCurrencyProvider`). Used as the report's primary currency when it is
  /// present in [currencyTotals]; otherwise the dominant currency is used.
  final String? baseCurrency;
}
