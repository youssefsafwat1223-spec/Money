import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../domain/entities/transaction_entity.dart';
import '../common/category_catalog.dart';

class TransactionsView {
  const TransactionsView({required this.transactions, required this.catalog});

  final List<TransactionEntity> transactions;
  final CategoryCatalog catalog;
}

final transactionsListProvider = FutureProvider<TransactionsView>((ref) async {
  final txRepo = ref.watch(transactionRepositoryProvider);
  final catalog = await ref.watch(categoryCatalogProvider.future);
  final transactions = await txRepo.getAll();
  return TransactionsView(transactions: transactions, catalog: catalog);
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
}
