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
  });

  final List<TransactionEntity> transactions;
  final CategoryCatalog catalog;
  final TransactionsDateRange range;

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

enum TransactionsDatePreset { thisMonth, previousMonth, last30Days, custom }

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
        TransactionsDatePreset.thisMonth => 'هذا الشهر',
        TransactionsDatePreset.previousMonth => 'الشهر السابق',
        TransactionsDatePreset.last30Days => 'آخر 30 يوم',
        TransactionsDatePreset.custom => 'مخصص',
      };
}

TransactionsDateRange defaultTransactionsRange() {
  final now = DateTime.now();
  return TransactionsDateRange(
    preset: TransactionsDatePreset.thisMonth,
    from: DateTime(now.year, now.month),
    to: now,
  );
}

final transactionsDateRangeProvider =
    StateProvider<TransactionsDateRange>((ref) => defaultTransactionsRange());

final transactionKindFilterProvider =
    StateProvider<TransactionKindFilter>((ref) => TransactionKindFilter.all);

final transactionSearchQueryProvider = StateProvider<String>((ref) => '');

final transactionsPageTabProvider = StateProvider<int>((ref) => 0);

final transactionsListProvider = FutureProvider<TransactionsView>((ref) async {
  final txRepo = ref.watch(transactionRepositoryProvider);
  final catalog = await ref.watch(categoryCatalogProvider.future);
  final range = ref.watch(transactionsDateRangeProvider);
  final kind = ref.watch(transactionKindFilterProvider);
  final query = ref.watch(transactionSearchQueryProvider).trim().toLowerCase();
  final all = await txRepo.getAll();
  final inRange = all.where((tx) {
    final at = tx.occurredAt;
    return !at.isBefore(range.from) && !at.isAfter(range.to);
  });
  final filteredByKind = inRange.where((tx) {
    return switch (kind) {
      TransactionKindFilter.all => true,
      TransactionKindFilter.expenses =>
        tx.type == TransactionTypeEntity.payment ||
            tx.type == TransactionTypeEntity.withdrawal,
      TransactionKindFilter.income => tx.type == TransactionTypeEntity.income ||
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
      transactions: filtered, catalog: catalog, range: range);
});

final billsViewProvider = FutureProvider<BillsView>((ref) async {
  final range = ref.watch(transactionsDateRangeProvider);
  final bills = await ref.watch(billRepositoryProvider).getAll();
  final suggestions =
      (await ref.watch(transactionRepositoryProvider).recurringCandidates())
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
  // الاعتماد على القائمة لإعادة التحميل عند التغيير.
  ref.watch(transactionsListProvider);
  return ref.watch(transactionRepositoryProvider).getById(id);
});

/// يُستدعى بعد أي تعديل لتحديث كل الشاشات.
void refreshTransactions(WidgetRef ref) {
  ref.invalidate(transactionsListProvider);
  ref.invalidate(billsViewProvider);
}
