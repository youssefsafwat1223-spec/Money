import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../domain/entities/bill_entity.dart';
import '../../domain/entities/report_models.dart';

/// الاشتراكات والأقساط المحفوظة يدوياً.
final savedBillsProvider = FutureProvider<List<BillEntity>>((ref) async {
  ref.watch(dbRevisionProvider);
  final accountRepo = ref.watch(accountRepositoryProvider);
  final selectedAccountId = ref.watch(activeAccountIdProvider);
  final selectedAccount = selectedAccountId == null
      ? null
      : await accountRepo.getById(selectedAccountId);
  final defaultAccount = await accountRepo.getDefault();
  final activeAccount = selectedAccount ?? defaultAccount;
  final bills = await ref.watch(billRepositoryProvider).getAll();
  return bills.where((bill) {
    if (activeAccount != null) {
      final matchesAccount = bill.accountId == activeAccount.id ||
          (bill.accountId == null &&
              bill.currency.toUpperCase() ==
                  activeAccount.currency.toUpperCase());
      if (!matchesAccount) return false;
    }
    return true;
  }).toList(growable: false);
});

final billPaymentsProvider =
    FutureProvider.family<List<BillPaymentEntity>, String>((ref, billId) async {
  ref.watch(dbRevisionProvider);
  return ref.watch(billRepositoryProvider).getPayments(billId);
});

/// الاشتراكات المكتشفة تلقائياً من المعاملات (مقترحات).
final subscriptionsProvider =
    FutureProvider<List<RecurringCandidate>>((ref) async {
  final accountRepo = ref.watch(accountRepositoryProvider);
  final selectedAccountId = ref.watch(activeAccountIdProvider);
  final selectedAccount = selectedAccountId == null
      ? null
      : await accountRepo.getById(selectedAccountId);
  final defaultAccount = await accountRepo.getDefault();
  final accountId = (selectedAccount ?? defaultAccount)?.id;
  return ref
      .watch(transactionRepositoryProvider)
      .recurringCandidates(accountId: accountId);
});
