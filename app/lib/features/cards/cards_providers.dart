import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../domain/entities/card_entity.dart';
import '../../domain/entities/card_summary.dart';
import '../../domain/entities/transaction_entity.dart';
import '../../domain/repositories/transaction_repository.dart';
import '../../domain/services/card_account_grouper.dart';

/// البطاقات الحقيقية (المُدارة) لحساب محدد — من جدول cards.
final accountCardsProvider =
    FutureProvider.family<List<CardEntity>, String>((ref, accountId) async {
  ref.watch(appSessionRevisionProvider);
  ref.watch(dbRevisionProvider);
  return ref.watch(cardRepositoryProvider).getByAccount(accountId);
});

/// كل البطاقات المُدارة (جدول cards) — تُستخدم لدمج البطاقات اليدوية (حتى بلا
/// عمليات بعد) في شاشة «كل البطاقات».
final allCardsProvider = FutureProvider<List<CardEntity>>((ref) async {
  ref.watch(appSessionRevisionProvider);
  ref.watch(dbRevisionProvider);
  return ref.watch(cardRepositoryProvider).getAll();
});

final cardSummariesProvider = FutureProvider<List<CardSummary>>((ref) async {
  ref.watch(appSessionRevisionProvider);
  ref.watch(dbRevisionProvider);
  return ref.watch(transactionRepositoryProvider).getCardSummaries();
});

/// البطاقات مُجمَّعة حسب الحساب (بثقة) + قائمة غير المخصّصة. أساس عرض البطاقات
/// داخل الحسابات وشاشة «كل البطاقات» المجمَّعة. قراءة فقط — لا يفرض ربطًا.
final accountCardGroupsProvider = FutureProvider<CardGrouping>((ref) async {
  ref.watch(appSessionRevisionProvider);
  ref.watch(dbRevisionProvider);
  final rows =
      await ref.watch(transactionRepositoryProvider).getCardAccountBreakdown();
  return const CardAccountGrouper().group(rows);
});

/// عمليات بطاقة محددة (بآخر 4 أرقام).
final cardTransactionsProvider =
    FutureProvider.family<List<TransactionEntity>, String>((ref, last4) async {
  ref.watch(appSessionRevisionProvider);
  return ref.watch(transactionRepositoryProvider).getByCard(last4);
});

/// B2-C — bounded, search-driven candidates for the card-linking picker (was an
/// unbounded `getAll()` over the whole ledger on a UI path). The [query] is
/// pushed into SQL, so a match anywhere in the ledger is found within the
/// bounded page and the load never scales with ledger size. autoDispose family
/// so each settled search term is cached and cleaned up.
final pickTransactionsProvider = FutureProvider.autoDispose
    .family<List<TransactionEntity>, String>((ref, query) async {
  ref.watch(appSessionRevisionProvider);
  final trimmed = query.trim();
  return ref.read(transactionRepositoryProvider).getTransactionPage(
        limit: 500,
        filter:
            TransactionPageFilter(search: trimmed.isEmpty ? null : trimmed),
      );
});
