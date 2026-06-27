import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../domain/entities/card_summary.dart';
import '../../domain/entities/transaction_entity.dart';

final cardSummariesProvider = FutureProvider<List<CardSummary>>((ref) async {
  ref.watch(dbRevisionProvider);
  return ref.watch(transactionRepositoryProvider).getCardSummaries();
});

/// عمليات بطاقة محددة (بآخر 4 أرقام).
final cardTransactionsProvider =
    FutureProvider.family<List<TransactionEntity>, String>((ref, last4) async {
  return ref.watch(transactionRepositoryProvider).getByCard(last4);
});

/// كل العمليات — لاختيار عملية موجودة وربطها ببطاقة.
final allTransactionsForPickProvider =
    FutureProvider<List<TransactionEntity>>((ref) async {
  return ref.watch(transactionRepositoryProvider).getAll();
});
