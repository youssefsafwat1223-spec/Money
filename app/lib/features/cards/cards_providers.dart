import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../domain/entities/card_entity.dart';
import '../../domain/entities/card_summary.dart';
import '../../domain/entities/transaction_entity.dart';
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

/// كل العمليات — لاختيار عملية موجودة وربطها ببطاقة.
final allTransactionsForPickProvider =
    FutureProvider<List<TransactionEntity>>((ref) async {
  ref.watch(appSessionRevisionProvider);
  return ref.watch(transactionRepositoryProvider).getAll();
});
