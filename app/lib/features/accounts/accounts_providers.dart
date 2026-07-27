import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../domain/entities/transaction_entity.dart';

/// أحدث عمليات حساب محدد — لعرضها في شاشة تفاصيل الحساب. قراءة فقط.
final accountRecentTransactionsProvider =
    FutureProvider.family<List<TransactionEntity>, String>(
        (ref, accountId) async {
  ref.watch(appSessionRevisionProvider);
  ref.watch(dbRevisionProvider);
  return ref
      .watch(transactionRepositoryProvider)
      .getRecent(limit: 20, accountId: accountId);
});
