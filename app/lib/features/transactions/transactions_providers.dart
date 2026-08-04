import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../domain/entities/bill_entity.dart';
import '../../domain/entities/transaction_entity.dart';
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

  @override
  Future<TransactionsView> build() async {
    ref.watch(dbRevisionProvider);
    ref.watch(transactionsDateRangeProvider);
    ref.watch(transactionKindFilterProvider);
    ref.watch(transactionCategoryFilterProvider);
    ref.watch(transactionSearchQueryProvider);
    ref.watch(transactionsPendingFilterProvider);
    ref.watch(activeAccountIdProvider);
    _loaded = const [];
    _hasMore = true;
    _loadingMore = false;
    return _loadNextPage();
  }

  Future<void> loadMore() async {
    if (_loadingMore || !_hasMore) return;
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
    try {
      final view = await _loadNextPage();
      state = AsyncData(view);
    } catch (error, stackTrace) {
      state = AsyncError(error, stackTrace);
    }
  }

  Future<TransactionsView> _loadNextPage() async {
    _loadingMore = true;
    final txRepo = ref.read(transactionRepositoryProvider);
    final page = await txRepo.getPage(
      offset: _loaded.length,
      limit: transactionsPageSize,
    );
    final existingIds = _loaded.map((t) => t.id).toSet();
    final newItems = page.where((t) => !existingIds.contains(t.id));
    _loaded = [..._loaded, ...newItems];
    _hasMore = page.length == transactionsPageSize;
    _loadingMore = false;
    return _viewForLoaded();
  }

  Future<TransactionsView> _viewForLoaded() async {
    final accountRepo = ref.read(accountRepositoryProvider);
    final catalog = await ref.read(categoryCatalogProvider.future);
    final range =
        effectiveTransactionsRange(ref.read(transactionsDateRangeProvider));
    final kind = ref.read(transactionKindFilterProvider);
    final categoryId = ref.read(transactionCategoryFilterProvider);
    final query = ref.read(transactionSearchQueryProvider).trim().toLowerCase();
    final pendingOnly = ref.read(transactionsPendingFilterProvider);
    final selectedAccountId = ref.read(activeAccountIdProvider);
    final selectedAccount = selectedAccountId == null
        ? null
        : await accountRepo.getById(selectedAccountId);
    final defaultAccount = await accountRepo.getDefault();
    final activeAccount = selectedAccount ?? defaultAccount;
    final all = _loaded;
    // MALI-074n: exact account ownership — an unassigned (null-account) row is
    // NOT shown under a specific account just because its currency matches
    // (that made one orphan appear under every same-currency account). It
    // appears only in the all-accounts scope. Matches the header aggregate.
    final scoped = all.where((tx) {
      if (activeAccount == null) return true;
      return tx.accountId == activeAccount.id;
    });
    final inRange = scoped.where((tx) {
      if (pendingOnly) return tx.status == TransactionStatus.pending;
      final at = tx.occurredAt;
      // Half-open [from, to) — consistent with the canonical period aggregates.
      return !at.isBefore(range.from) && at.isBefore(range.to);
    });
    final filteredByKind = inRange.where((tx) {
      if (pendingOnly) return true;
      return switch (kind) {
        TransactionKindFilter.all => true,
        TransactionKindFilter.expenses =>
          tx.type == TransactionTypeEntity.payment ||
              tx.type == TransactionTypeEntity.withdrawal,
        TransactionKindFilter.income =>
          tx.type == TransactionTypeEntity.income ||
              tx.type == TransactionTypeEntity.refund,
        TransactionKindFilter.transfers =>
          tx.type == TransactionTypeEntity.transfer,
      };
    });
    final filteredByCategory = filteredByKind.where((tx) {
      if (categoryId == null) return true;
      return tx.categoryId == categoryId;
    });
    final filtered = filteredByCategory.where((tx) {
      if (query.isEmpty) return true;
      final category = catalog.byId(tx.categoryId);
      final haystack = [
        tx.rawMerchant,
        tx.currency,
        tx.amount.toStringAsFixed(2),
        category?.nameAr,
        category?.key,
        tx.note,
      ].whereType<String>().join(' ').toLowerCase();
      return haystack.contains(query);
    }).toList(growable: false);
    return TransactionsView(
      transactions: filtered,
      catalog: catalog,
      range: range,
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
