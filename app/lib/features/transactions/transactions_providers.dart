import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../domain/entities/bill_entity.dart';
import '../../domain/entities/transaction_entity.dart';
import '../../domain/repositories/transaction_repository.dart';
import '../common/category_catalog.dart';

class TransactionsView {
  const TransactionsView({
    required this.transactions,
    required this.catalog,
    required this.range,
    this.hasMore = false,
    this.isLoadingMore = false,
  });

  final List<TransactionEntity> transactions;
  final CategoryCatalog catalog;
  final TransactionsDateRange range;
  final bool hasMore;
  final bool isLoadingMore;

  /// Count of pending rows in the currently-loaded/visible list — a UX
  /// affordance for the "قيد المراجعة" chip and the confirm-all action, which
  /// both operate on the visible list. The financial period expense total is
  /// NOT derived here (it was the non-canonical fold behind MALI-047n); it now
  /// comes from [transactionsPeriodTotalProvider] over the complete dataset.
  int get pendingCount =>
      transactions.where((tx) => tx.status == TransactionStatus.pending).length;
}

const transactionsPageSize = 500;

class BillsView {
  const BillsView({
    required this.bills,
    required this.suggestions,
    required this.range,
  });

  final List<BillEntity> bills;
  final List<BillSuggestion> suggestions;
  final TransactionsDateRange range;

  int get subscriptionsCount =>
      bills.where((bill) => bill.type == BillType.subscription).length;
  int get installmentsCount =>
      bills.where((bill) => bill.type == BillType.installment).length;
  // MALI-074n: the dead `totalDue` getter (a raw cross-frequency/currency fold
  // of `bill.amount`, no consumer) was removed — the canonical monthly metric is
  // `subscriptionMonthlyTotal` (bill_metrics.dart).
}

class BillSuggestion {
  const BillSuggestion({
    required this.merchantId,
    required this.name,
    required this.averageAmount,
    required this.monthsSeen,
  });

  final String merchantId;
  final String name;
  final double averageAmount;
  final int monthsSeen;
}

enum TransactionsDatePreset {
  today,
  thisWeek,
  thisMonth,
  previousMonth,
  last7Days,
  last30Days,
  last90Days,
  custom,
}

enum TransactionKindFilter { all, expenses, income, transfers }

class TransactionsDateRange {
  const TransactionsDateRange({
    required this.preset,
    required this.from,
    required this.to,
  });

  final TransactionsDatePreset preset;
  final DateTime from;
  final DateTime to;

  String get label => switch (preset) {
        TransactionsDatePreset.today => 'اليوم',
        TransactionsDatePreset.thisWeek => 'هذا الأسبوع',
        TransactionsDatePreset.thisMonth => 'هذا الشهر',
        TransactionsDatePreset.previousMonth => 'الشهر السابق',
        TransactionsDatePreset.last7Days => 'آخر 7 أيام',
        TransactionsDatePreset.last30Days => 'آخر 30 يوم',
        TransactionsDatePreset.last90Days => 'آخر 90 يوم',
        TransactionsDatePreset.custom => 'مخصص',
      };
}

TransactionsDateRange defaultTransactionsRange() {
  return transactionsRangeForPreset(TransactionsDatePreset.thisMonth);
}

TransactionsDateRange transactionsRangeForPreset(
  TransactionsDatePreset preset, {
  DateTime? now,
  TransactionsDateRange? customFallback,
}) {
  final current = now ?? DateTime.now();
  final today = DateTime(current.year, current.month, current.day);
  final weekStart = today.subtract(
    Duration(days: (current.weekday - DateTime.saturday) % 7),
  );
  return switch (preset) {
    TransactionsDatePreset.today => TransactionsDateRange(
        preset: preset,
        from: today,
        to: current,
      ),
    TransactionsDatePreset.thisWeek => TransactionsDateRange(
        preset: preset,
        from: weekStart,
        to: current,
      ),
    TransactionsDatePreset.thisMonth => TransactionsDateRange(
        preset: preset,
        from: DateTime(current.year, current.month),
        to: current,
      ),
    TransactionsDatePreset.previousMonth => TransactionsDateRange(
        preset: preset,
        from: DateTime(current.year, current.month - 1),
        to: DateTime(current.year, current.month)
            .subtract(const Duration(seconds: 1)),
      ),
    TransactionsDatePreset.last7Days => TransactionsDateRange(
        preset: preset,
        from: current.subtract(const Duration(days: 7)),
        to: current,
      ),
    TransactionsDatePreset.last30Days => TransactionsDateRange(
        preset: preset,
        from: current.subtract(const Duration(days: 30)),
        to: current,
      ),
    TransactionsDatePreset.last90Days => TransactionsDateRange(
        preset: preset,
        from: current.subtract(const Duration(days: 90)),
        to: current,
      ),
    TransactionsDatePreset.custom => customFallback ??
        TransactionsDateRange(preset: preset, from: today, to: current),
  };
}

TransactionsDateRange effectiveTransactionsRange(
  TransactionsDateRange range, {
  DateTime? now,
}) {
  if (range.preset == TransactionsDatePreset.custom) return range;
  return transactionsRangeForPreset(range.preset, now: now);
}

final transactionsDateRangeProvider =
    StateProvider<TransactionsDateRange>((ref) => defaultTransactionsRange());

final transactionKindFilterProvider =
    StateProvider<TransactionKindFilter>((ref) => TransactionKindFilter.all);

/// Selected category filter (by category id). `null` means all categories.
final transactionCategoryFilterProvider = StateProvider<String?>((ref) => null);

final transactionSearchQueryProvider = StateProvider<String>((ref) => '');

final transactionsPageTabProvider = StateProvider<int>((ref) => 0);

/// When true, the transactions list shows only pending-review transactions.
/// Automatically reset to false when the user leaves the transactions tab.
final transactionsPendingFilterProvider = StateProvider<bool>((ref) => false);

final transactionsListProvider = AutoDisposeAsyncNotifierProvider<
    TransactionsListNotifier, TransactionsView>(
  TransactionsListNotifier.new,
);

class TransactionsListNotifier
    extends AutoDisposeAsyncNotifier<TransactionsView> {
  var _loaded = <TransactionEntity>[];
  var _hasMore = true;
  var _loadingMore = false;
  TransactionPageCursor? _cursor;
  // B2-C — bumped on every build (any filter/search/owner change). An in-flight
  // loadMore captures the generation and drops its page if a newer build has
  // superseded it, so a page fetched under an old filter can never overwrite the
  // newer result ("stale result cannot overwrite a newer one").
  var _buildGen = 0;
  // B2-C — the effective filter + display context are resolved ONCE per build
  // (all dimensions are watched below, so build() re-runs on any change and
  // resets the cursor). loadMore() reuses them, so a page can never be produced
  // for one filter and appended to another.
  late TransactionPageFilter _filter;
  late CategoryCatalog _catalog;
  late TransactionsDateRange _range;

  @override
  Future<TransactionsView> build() async {
    // MALI-029 — scoped to the transaction-list domain (rows + their category
    // labels + account filter), so an unrelated write (goals, notifications, sync
    // bookkeeping) no longer reloads and re-groups the whole list.
    ref.watch(scopedRevisionProvider(kTransactionsRevisionTables));
    ref.watch(transactionsDateRangeProvider);
    ref.watch(transactionKindFilterProvider);
    ref.watch(transactionCategoryFilterProvider);
    ref.watch(transactionSearchQueryProvider);
    ref.watch(transactionsPendingFilterProvider);
    ref.watch(activeAccountIdProvider);
    _loaded = const [];
    _hasMore = true;
    _loadingMore = false;
    _cursor = null;
    _buildGen++;
    _catalog = await ref.read(categoryCatalogProvider.future);
    _range = effectiveTransactionsRange(ref.read(transactionsDateRangeProvider));
    _filter = await _resolveFilter();
    return _loadNextPage();
  }

  /// Resolve the screen's filter providers into the SQL filter pushed to the
  /// repository — matching the old in-Dart filter semantics exactly (pending-only
  /// forces status=pending and drops date+kind; active account = selected ??
  /// default; no active account ⇒ no account predicate = all-accounts scope).
  Future<TransactionPageFilter> _resolveFilter() async {
    final accountRepo = ref.read(accountRepositoryProvider);
    final range = _range;
    final kind = ref.read(transactionKindFilterProvider);
    final categoryId = ref.read(transactionCategoryFilterProvider);
    final query = ref.read(transactionSearchQueryProvider).trim();
    final pendingOnly = ref.read(transactionsPendingFilterProvider);
    final selectedAccountId = ref.read(activeAccountIdProvider);
    final selectedAccount = selectedAccountId == null
        ? null
        : await accountRepo.getById(selectedAccountId);
    final defaultAccount = await accountRepo.getDefault();
    final activeAccount = selectedAccount ?? defaultAccount;
    return TransactionPageFilter(
      accountId: activeAccount?.id,
      from: pendingOnly ? null : range.from,
      to: pendingOnly ? null : range.to,
      kind: pendingOnly ? TransactionPageKind.all : _mapKind(kind),
      categoryId: categoryId,
      search: query.isEmpty ? null : query,
      pendingOnly: pendingOnly,
    );
  }

  static TransactionPageKind _mapKind(TransactionKindFilter kind) =>
      switch (kind) {
        TransactionKindFilter.all => TransactionPageKind.all,
        TransactionKindFilter.expenses => TransactionPageKind.expenses,
        TransactionKindFilter.income => TransactionPageKind.income,
        TransactionKindFilter.transfers => TransactionPageKind.transfers,
      };

  Future<void> loadMore() async {
    if (_loadingMore || !_hasMore) return;
    final gen = _buildGen;
    final current = state.valueOrNull;
    if (current != null) {
      state = AsyncData(TransactionsView(
        transactions: current.transactions,
        catalog: current.catalog,
        range: current.range,
        hasMore: current.hasMore,
        isLoadingMore: true,
      ));
    }
    _loadingMore = true;
    final txRepo = ref.read(transactionRepositoryProvider);
    // B2-C — keyset page, fully SQL-filtered. No OFFSET, no full-history load,
    // no load-then-discard-in-Dart. Keyset (occurred_at DESC, id DESC) means a
    // page never overlaps the previous one, so no de-dup is needed.
    try {
      final page = await txRepo.getTransactionPage(
        limit: transactionsPageSize,
        after: _cursor,
        filter: _filter,
      );
      // A newer build (filter/search/owner change) superseded this page while it
      // was in flight — drop it so it can't append to (or overwrite) the newer
      // result. The newer build already owns _loaded/_cursor/state.
      if (gen != _buildGen) return;
      _loaded = [..._loaded, ...page];
      if (page.isNotEmpty) {
        final last = page.last;
        _cursor =
            TransactionPageCursor(occurredAt: last.occurredAt, id: last.id);
      }
      _hasMore = page.length == transactionsPageSize;
      _loadingMore = false;
      state = AsyncData(TransactionsView(
        transactions: _loaded,
        catalog: _catalog,
        range: _range,
        hasMore: _hasMore,
        isLoadingMore: _loadingMore,
      ));
    } catch (error, stackTrace) {
      if (gen != _buildGen) return;
      _loadingMore = false;
      state = AsyncError(error, stackTrace);
    }
  }

  Future<TransactionsView> _loadNextPage() async {
    _loadingMore = true;
    final txRepo = ref.read(transactionRepositoryProvider);
    final page = await txRepo.getTransactionPage(
      limit: transactionsPageSize,
      after: _cursor,
      filter: _filter,
    );
    _loaded = [..._loaded, ...page];
    if (page.isNotEmpty) {
      final last = page.last;
      _cursor = TransactionPageCursor(occurredAt: last.occurredAt, id: last.id);
    }
    _hasMore = page.length == transactionsPageSize;
    _loadingMore = false;
    return TransactionsView(
      transactions: _loaded,
      catalog: _catalog,
      range: _range,
      hasMore: _hasMore,
      isLoadingMore: _loadingMore,
    );
  }
}

/// The canonical Transactions-header total (MALI-047n).
///
/// Metric contract — the header's "إجمالي مصروفات الفترة" is the **canonical
/// net expense** (payment + withdrawal − refund) over the COMPLETE matching
/// dataset for the visible **period × active-account** scope, confirmed-only:
///   - pagination cannot change it (it is a set-based Drift aggregate, never a
///     fold over loaded pages);
///   - pending / ignored / deleted rows never count (canonical status contract);
///   - a refund reduces expense and is never counted as income;
///   - withdrawal follows the expense contract; transfer/unknown are excluded;
///   - the excluded-from-totals account policy applies only in the all-accounts
///     (no active account) case, matching the repository aggregate;
///   - it is single-currency: the active account fixes the currency, so mixed
///     currencies are never summed under one label. With no active account the
///     base currency's own total is shown via [currencyTotalsBetween] (grouped
///     by currency — never a cross-currency sum);
///   - free-text search and the kind/category list filters do NOT change it —
///     the header explicitly claims the *period* expense, not the filtered
///     subset (the list below reflects those filters).
/// Computed from Drift, so it is always available offline.
class TransactionsPeriodTotal {
  const TransactionsPeriodTotal({
    required this.netExpense,
    required this.currency,
  });

  final double netExpense;
  final String currency;
}

final transactionsPeriodTotalProvider =
    FutureProvider<TransactionsPeriodTotal>((ref) async {
  ref.watch(dbRevisionProvider);
  final range =
      effectiveTransactionsRange(ref.watch(transactionsDateRangeProvider));
  final txRepo = ref.watch(transactionRepositoryProvider);
  final accountRepo = ref.watch(accountRepositoryProvider);
  final selectedAccountId = ref.watch(activeAccountIdProvider);
  final selectedAccount = selectedAccountId == null
      ? null
      : await accountRepo.getById(selectedAccountId);
  final defaultAccount = await accountRepo.getDefault();
  final activeAccount = selectedAccount ?? defaultAccount;

  // Half-open [from, to): the account fixes a single currency, so this is a
  // clean single-currency total.
  if (activeAccount != null) {
    final netExpense = await txRepo.expenseTotalBetween(
      from: range.from,
      to: range.to,
      accountId: activeAccount.id,
    );
    return TransactionsPeriodTotal(
      netExpense: netExpense,
      currency: activeAccount.currency,
    );
  }

  // No active account (no accounts yet / all-currencies): never sum across
  // currencies — group by currency and surface only the base currency's total.
  final base = await ref.watch(baseCurrencyProvider.future);
  final perCurrency =
      await txRepo.currencyTotalsBetween(from: range.from, to: range.to);
  final match = perCurrency
      .where((c) => c.currency.toUpperCase() == base.toUpperCase())
      .toList(growable: false);
  return TransactionsPeriodTotal(
    netExpense: match.isEmpty ? 0 : match.first.expense,
    currency: base,
  );
});

final billsViewProvider = FutureProvider<BillsView>((ref) async {
  ref.watch(dbRevisionProvider);
  final range =
      effectiveTransactionsRange(ref.watch(transactionsDateRangeProvider));
  final billRepo = ref.watch(billRepositoryProvider);
  final accountRepo = ref.watch(accountRepositoryProvider);
  final selectedAccountId = ref.watch(activeAccountIdProvider);
  final selectedAccount = selectedAccountId == null
      ? null
      : await accountRepo.getById(selectedAccountId);
  final defaultAccount = await accountRepo.getDefault();
  final activeAccount = selectedAccount ?? defaultAccount;
  final allBills = await billRepo.getAll();
  final bills = allBills.where((bill) {
    if (activeAccount != null) {
      final matchesAccount = bill.accountId == activeAccount.id ||
          (bill.accountId == null &&
              bill.currency.toUpperCase() ==
                  activeAccount.currency.toUpperCase());
      if (!matchesAccount) return false;
    }
    return true;
  }).toList(growable: false);
  final suggestions = (await ref
          .watch(transactionRepositoryProvider)
          .recurringCandidates(accountId: activeAccount?.id))
      .map(
        (item) => BillSuggestion(
          merchantId: item.merchantId,
          name: item.name,
          averageAmount: item.averageAmount,
          monthsSeen: item.monthsSeen,
        ),
      )
      .toList(growable: false);
  return BillsView(bills: bills, suggestions: suggestions, range: range);
});

/// عملية واحدة بالـ id (لشاشة التفاصيل).
final transactionByIdProvider =
    FutureProvider.family<TransactionEntity?, String>((ref, id) async {
  // React to DB changes without depending on the heavy list provider,
  // which rebuilds on every filter/range/search change and causes
  // unnecessary cascading refreshes of this single-record lookup.
  ref.watch(dbRevisionProvider);
  return ref.watch(transactionRepositoryProvider).getById(id);
});

/// يُستدعى بعد أي تعديل لتحديث كل الشاشات.
void refreshTransactions(WidgetRef ref) {
  ref.invalidate(transactionsListProvider);
  ref.invalidate(billsViewProvider);
}
