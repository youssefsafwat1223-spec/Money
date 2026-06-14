import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../domain/entities/bill_entity.dart';
import '../../domain/entities/report_models.dart';

/// الاشتراكات والأقساط المحفوظة يدوياً.
final savedBillsProvider = FutureProvider<List<BillEntity>>((ref) async {
  return ref.watch(billRepositoryProvider).getAll();
});

/// الاشتراكات المكتشفة تلقائياً من المعاملات (مقترحات).
final subscriptionsProvider =
    FutureProvider<List<RecurringCandidate>>((ref) async {
  return ref.watch(transactionRepositoryProvider).recurringCandidates();
});
