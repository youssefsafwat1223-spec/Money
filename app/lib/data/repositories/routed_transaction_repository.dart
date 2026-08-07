import '../../domain/entities/card_summary.dart';
import '../../domain/entities/category_spend.dart';
import '../../domain/entities/report_models.dart';
import '../../domain/entities/transaction_entity.dart';
import '../../domain/repositories/transaction_repository.dart';
import '../../domain/services/card_account_grouper.dart';

/// S5: توجيه المرحلة-A أُزيل — غلاف رفيع يفوّض إلى Drift (بما فيها التقارير
/// المُجمَّعة). لم تعد هناك قراءة مالية على Supabase من الواجهة. المزامنة خلفية.
class RoutedTransactionRepository implements TransactionRepository {
  const RoutedTransactionRepository({required TransactionRepository drift})
      : _drift = drift;

  final TransactionRepository _drift;

  @override
  Future<TransactionEntity?> findDuplicate({
    required double amount,
    required String rawMerchant,
    required DateTime occurredAt,
  }) =>
      _drift.findDuplicate(
          amount: amount, rawMerchant: rawMerchant, occurredAt: occurredAt);

  @override
  Future<TransactionEntity?> findSuspiciousDuplicate({
    required double amount,
    required String currency,
    required String merchantOrDescription,
    String? cardLast4,
    required DateTime comparisonTimestamp,
  }) =>
      _drift.findSuspiciousDuplicate(
        amount: amount,
        currency: currency,
        merchantOrDescription: merchantOrDescription,
        cardLast4: cardLast4,
        comparisonTimestamp: comparisonTimestamp,
      );

  @override
  Future<TransactionEntity> saveTransaction({
    required TransactionEntity transaction,
    required String? categoryKey,
  }) =>
      _drift.saveTransaction(
          transaction: transaction, categoryKey: categoryKey);

  @override
  Future<TransactionEntity?> getById(String id) => _drift.getById(id);

  @override
  Future<TransactionEntity> confirm(String id) => _drift.confirm(id);

  @override
  Future<TransactionEntity> updateCategory({
    required String transactionId,
    required String categoryKey,
  }) =>
      _drift.updateCategory(
          transactionId: transactionId, categoryKey: categoryKey);

  @override
  Future<TransactionEntity> updateTransaction({
    required String transactionId,
    required double amount,
    required String currency,
    required TransactionTypeEntity type,
    required DateTime occurredAt,
    required String? rawMerchant,
    required String? categoryId,
    required String? note,
    String? accountId,
  }) =>
      _drift.updateTransaction(
        transactionId: transactionId,
        amount: amount,
        currency: currency,
        type: type,
        occurredAt: occurredAt,
        rawMerchant: rawMerchant,
        categoryId: categoryId,
        note: note,
        accountId: accountId,
      );

  @override
  Future<void> deleteTransaction(String id) => _drift.deleteTransaction(id);

  @override
  Future<void> updateAccount(
          {required String transactionId, required String accountId}) =>
      _drift.updateAccount(transactionId: transactionId, accountId: accountId);

  @override
  Future<void> updateCard(
          {required String transactionId, required String? cardLast4}) =>
      _drift.updateCard(transactionId: transactionId, cardLast4: cardLast4);

  @override
  Future<void> updateAmount(
          {required String transactionId, required double amount}) =>
      _drift.updateAmount(transactionId: transactionId, amount: amount);

  @override
  Future<List<TransactionEntity>> getRecent(
          {int limit = 5, String? accountId}) =>
      _drift.getRecent(limit: limit, accountId: accountId);

  @override
  Future<List<TransactionEntity>> getAll() => _drift.getAll();

  @override
  Future<List<TransactionEntity>> getPage(
          {required int offset, int limit = 500}) =>
      _drift.getPage(offset: offset, limit: limit);

  @override
  Future<List<TransactionEntity>> getByCard(String last4) =>
      _drift.getByCard(last4);

  @override
  Future<double> expenseTotalBetween(
          {required DateTime from, required DateTime to, String? accountId}) =>
      _drift.expenseTotalBetween(from: from, to: to, accountId: accountId);

  @override
  Future<List<TransactionEntity>> largestExpenses(
          {required DateTime from,
          required DateTime to,
          String? accountId,
          int limit = 10}) =>
      _drift.largestExpenses(
          from: from, to: to, accountId: accountId, limit: limit);

  @override
  Future<double> incomeTotalBetween(
          {required DateTime from, required DateTime to, String? accountId}) =>
      _drift.incomeTotalBetween(from: from, to: to, accountId: accountId);

  @override
  Future<double?> latestBalanceAfter({String? accountId}) =>
      _drift.latestBalanceAfter(accountId: accountId);

  @override
  Future<List<CurrencyTotal>> currencyTotalsBetween(
          {required DateTime from, required DateTime to}) =>
      _drift.currencyTotalsBetween(from: from, to: to);

  @override
  Future<List<DailySpend>> dailyExpenseTotals(
          {required DateTime from, required DateTime to, String? accountId}) =>
      _drift.dailyExpenseTotals(from: from, to: to, accountId: accountId);

  @override
  Future<List<CategorySpend>> categoryBreakdown(
          {required DateTime from,
          required DateTime to,
          String? accountId,
          String? currency}) =>
      _drift.categoryBreakdown(
          from: from, to: to, accountId: accountId, currency: currency);

  @override
  Future<double> categoryExpenseTotalBetween({
    required String categoryId,
    required DateTime from,
    required DateTime to,
    String? accountId,
  }) =>
      _drift.categoryExpenseTotalBetween(
          categoryId: categoryId, from: from, to: to, accountId: accountId);

  @override
  Future<List<MerchantSpend>> merchantBreakdown({
    required DateTime from,
    required DateTime to,
    int limit = 3,
    String? accountId,
  }) =>
      _drift.merchantBreakdown(
          from: from, to: to, limit: limit, accountId: accountId);

  @override
  Future<List<RecurringCandidate>> recurringCandidates({String? accountId}) =>
      _drift.recurringCandidates(accountId: accountId);

  @override
  Future<List<CardSummary>> getCardSummaries() => _drift.getCardSummaries();

  @override
  Future<List<CardAccountBreakdownRow>> getCardAccountBreakdown() =>
      _drift.getCardAccountBreakdown();
}
