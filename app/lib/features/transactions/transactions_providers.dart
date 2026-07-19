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

  int get pendingCount =>
      transactions.where((tx) => tx.status == TransactionStatus.pending).length;

  double get expenseTotal => transactions
      .where((tx) =>
          tx.type == TransactionTypeEntity.payment ||
          tx.type == TransactionTypeEntity.withdrawal)
      .fold<double>(0, (sum, tx) => sum + tx.amount);

  double get incomeTotal => transactions
      .where((tx) =>
          tx.type == TransactionTypeEntity.income ||
          tx.type == TransactionTypeEntity.refund)
      .fold<double>(0, (sum, tx) => sum + tx.amount);

  double get transferTotal => transactions
      .where((tx) => tx.type == TransactionTypeEntity.transfer)
      .fold<double>(0, (sum, tx) => sum + tx.amount);
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
  double get totalDue =>
      bills.fold<double>(0, (sum, bill) => sum + bill.amount);
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
    final query = ref.read(transactionSearchQueryProvider).trim().toLowerCase();
    final pendingOnly = ref.read(transactionsPendingFilterProvider);
    final selectedAccountId = ref.read(activeAccountIdProvider);
    final selectedAccount = selectedAccountId == null
        ? null
        : await accountRepo.getById(selectedAccountId);
    final defaultAccount = await accountRepo.getDefault();
    final activeAccount = selectedAccount ?? defaultAccount;
    final all = _loaded;
    final scoped = all.where((tx) {
      if (activeAccount == null) return true;
      if (tx.accountId == activeAccount.id) return true;
      return tx.accountId == null &&
          tx.currency.toUpperCase() == activeAccount.currency.toUpperCase();
    });
    final inRange = scoped.where((tx) {
      if (pendingOnly) return tx.status == TransactionStatus.pending;
      final at = tx.occurredAt;
      return !at.isBefore(range.from) && !at.isAfter(range.to);
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
    final filtered = filteredByKind.where((tx) {
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
