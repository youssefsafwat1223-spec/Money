import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../domain/entities/account_entity.dart';
import '../../domain/entities/bill_entity.dart';
import '../../domain/entities/report_models.dart';

/// UX-024 — the account this screen is actually scoped to.
///
/// The QA's finding was that the scoping is correct and invisible: with الراجحي
/// selected the screen showed STC + iPhone and correctly hid Netflix and نادي
/// فيتنس تايم, while the tabs read «الاشتراكات (1)» — which says *"you have one
/// subscription"*, not *"one on this account"*.
///
/// The resolution (explicit selection, else the default account) is extracted
/// so the screen names the SAME account the filter used. Recomputing it in the
/// header would let the label and the filter drift apart, which is a worse
/// defect than the silence it replaces.
final billsScopeAccountProvider = FutureProvider<AccountEntity?>((ref) async {
  ref.watch(dbRevisionProvider);
  final accountRepo = ref.watch(accountRepositoryProvider);
  final selectedAccountId = ref.watch(activeAccountIdProvider);
  final selectedAccount = selectedAccountId == null
      ? null
      : await accountRepo.getById(selectedAccountId);
  return selectedAccount ?? await accountRepo.getDefault();
});

/// الاشتراكات والأقساط المحفوظة يدوياً.
final savedBillsProvider = FutureProvider<List<BillEntity>>((ref) async {
  ref.watch(dbRevisionProvider);
  final activeAccount = await ref.watch(billsScopeAccountProvider.future);
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
