import '../../data/catalog/feature_flag_service.dart';
import '../../data/db/app_database.dart';
import '../../data/db/financial_cache_health.dart';
import '../../domain/entities/card_summary.dart';
import '../../domain/entities/category_spend.dart';
import '../../domain/entities/report_models.dart';
import '../../domain/entities/transaction_entity.dart';
import '../../domain/errors/repo_exceptions.dart';
import '../../domain/repositories/transaction_repository.dart';

/// يوجّه كل استدعاء لـ TransactionRepository إلى Drift أو Supabase حسب
/// علامة transactions_supabase_primary — تُفحص داخل كل دالة، بلا استثناء لأي
/// دالة قراءة (بما فيها التقارير المُجمَّعة)، حتى لا يبقى أي قراءة مالية
/// تعتمد على Drift بصمت أثناء تفعيل العلامة.
class RoutedTransactionRepository implements TransactionRepository {
  RoutedTransactionRepository({
    required TransactionRepository drift,
    required TransactionRepository supabase,
    required FeatureFlagService Function() flags,
    required AppDatabase db,
  })  : _drift = drift,
        _supabase = supabase,
        _flags = flags,
        _db = db;

  final TransactionRepository _drift;
  final TransactionRepository _supabase;
  // دالة وليس مرجعًا مباشرًا — أنظر التعليق المطابق في RoutedAccountRepository.
  final FeatureFlagService Function() _flags;
  final AppDatabase _db;

  // Transaction rows reference server account UUIDs. Keep the old Drift path
  // unless both cutovers are enabled, so an accidental transaction-only QA
  // override cannot send local account IDs into the server FK.
  bool get _transactionsPrimaryRequested =>
      _flags().getBool('transactions_supabase_primary');

  bool get _useSupabase {
    final flags = _flags();
    return flags.getBool('accounts_supabase_primary') &&
        flags.getBool('transactions_supabase_primary');
  }

  Future<T> _route<T>(
    Future<T> Function() supabase,
    Future<T> Function() drift,
  ) {
    if (_transactionsPrimaryRequested && !_useSupabase) {
      return Future<T>.error(
        const ServerRepoException('accounts_primary_required'),
      );
    }
    return routeFinancialOperation(
      db: _db,
      entityType: transactionsCacheEntityType,
      useSupabase: _useSupabase,
      supabase: supabase,
      drift: drift,
    );
  }

  @override
  Future<TransactionEntity?> findDuplicate({
    required double amount,
    required String rawMerchant,
    required DateTime occurredAt,
  }) =>
      _route(
        () => _supabase.findDuplicate(
          amount: amount,
          rawMerchant: rawMerchant,
          occurredAt: occurredAt,
        ),
        () => _drift.findDuplicate(
          amount: amount,
          rawMerchant: rawMerchant,
          occurredAt: occurredAt,
        ),
      );

  @override
  Future<TransactionEntity?> findSuspiciousDuplicate({
    required double amount,
    required String currency,
    required String merchantOrDescription,
    String? cardLast4,
    required DateTime comparisonTimestamp,
  }) =>
      _route(
        () => _supabase.findSuspiciousDuplicate(
          amount: amount,
          currency: currency,
          merchantOrDescription: merchantOrDescription,
          cardLast4: cardLast4,
          comparisonTimestamp: comparisonTimestamp,
        ),
        () => _drift.findSuspiciousDuplicate(
          amount: amount,
          currency: currency,
          merchantOrDescription: merchantOrDescription,
          cardLast4: cardLast4,
          comparisonTimestamp: comparisonTimestamp,
        ),
      );

  @override
  Future<TransactionEntity> saveTransaction({
    required TransactionEntity transaction,
    required String? categoryKey,
  }) =>
      _route(
        () => _supabase.saveTransaction(
          transaction: transaction,
          categoryKey: categoryKey,
        ),
        () => _drift.saveTransaction(
          transaction: transaction,
          categoryKey: categoryKey,
        ),
      );

  @override
  Future<TransactionEntity?> getById(String id) =>
      _route(() => _supabase.getById(id), () => _drift.getById(id));

  @override
  Future<TransactionEntity> confirm(String id) =>
      _route(() => _supabase.confirm(id), () => _drift.confirm(id));

  @override
  Future<TransactionEntity> updateCategory({
    required String transactionId,
    required String categoryKey,
  }) =>
      _route(
        () => _supabase.updateCategory(
          transactionId: transactionId,
          categoryKey: categoryKey,
        ),
        () => _drift.updateCategory(
          transactionId: transactionId,
          categoryKey: categoryKey,
        ),
      );

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
      _route(
        () => _supabase.updateTransaction(
          transactionId: transactionId,
          amount: amount,
          currency: currency,
          type: type,
          occurredAt: occurredAt,
          rawMerchant: rawMerchant,
          categoryId: categoryId,
          note: note,
          accountId: accountId,
        ),
        () => _drift.updateTransaction(
          transactionId: transactionId,
          amount: amount,
          currency: currency,
          type: type,
          occurredAt: occurredAt,
          rawMerchant: rawMerchant,
          categoryId: categoryId,
          note: note,
          accountId: accountId,
        ),
      );

  @override
  Future<void> deleteTransaction(String id) => _route(
        () => _supabase.deleteTransaction(id),
        () => _drift.deleteTransaction(id),
      );

  @override
  Future<void> updateAccount(
          {required String transactionId, required String accountId}) =>
      _route(
        () => _supabase.updateAccount(
          transactionId: transactionId,
          accountId: accountId,
        ),
        () => _drift.updateAccount(
          transactionId: transactionId,
          accountId: accountId,
        ),
      );

  @override
  Future<void> updateCard(
          {required String transactionId, required String? cardLast4}) =>
      _route(
        () => _supabase.updateCard(
          transactionId: transactionId,
          cardLast4: cardLast4,
        ),
        () => _drift.updateCard(
          transactionId: transactionId,
          cardLast4: cardLast4,
        ),
      );

  @override
  Future<void> updateAmount(
          {required String transactionId, required double amount}) =>
      _route(
        () => _supabase.updateAmount(
          transactionId: transactionId,
          amount: amount,
        ),
        () => _drift.updateAmount(
          transactionId: transactionId,
          amount: amount,
        ),
      );

  @override
  Future<List<TransactionEntity>> getRecent(
          {int limit = 5, String? accountId}) =>
      _route(
        () => _supabase.getRecent(limit: limit, accountId: accountId),
        () => _drift.getRecent(limit: limit, accountId: accountId),
      );

  @override
  Future<List<TransactionEntity>> getAll() =>
      _route(_supabase.getAll, _drift.getAll);

  @override
  Future<List<TransactionEntity>> getByCard(String last4) => _route(
        () => _supabase.getByCard(last4),
        () => _drift.getByCard(last4),
      );

  @override
  Future<double> expenseTotalBetween({
    required DateTime from,
    required DateTime to,
    String? accountId,
  }) =>
      _route(
        () => _supabase.expenseTotalBetween(
          from: from,
          to: to,
          accountId: accountId,
        ),
        () => _drift.expenseTotalBetween(
          from: from,
          to: to,
          accountId: accountId,
        ),
      );

  @override
  Future<double> incomeTotalBetween({
    required DateTime from,
    required DateTime to,
    String? accountId,
  }) =>
      _route(
        () => _supabase.incomeTotalBetween(
          from: from,
          to: to,
          accountId: accountId,
        ),
        () => _drift.incomeTotalBetween(
          from: from,
          to: to,
          accountId: accountId,
        ),
      );

  @override
  Future<double?> latestBalanceAfter({String? accountId}) => _route(
        () => _supabase.latestBalanceAfter(accountId: accountId),
        () => _drift.latestBalanceAfter(accountId: accountId),
      );

  @override
  Future<List<CurrencyTotal>> currencyTotalsBetween({
    required DateTime from,
    required DateTime to,
  }) =>
      _route(
        () => _supabase.currencyTotalsBetween(from: from, to: to),
        () => _drift.currencyTotalsBetween(from: from, to: to),
      );

  @override
  Future<List<DailySpend>> dailyExpenseTotals({
    required DateTime from,
    required DateTime to,
    String? accountId,
  }) =>
      _route(
        () => _supabase.dailyExpenseTotals(
          from: from,
          to: to,
          accountId: accountId,
        ),
        () => _drift.dailyExpenseTotals(
          from: from,
          to: to,
          accountId: accountId,
        ),
      );

  @override
  Future<List<CategorySpend>> categoryBreakdown({
    required DateTime from,
    required DateTime to,
    String? accountId,
  }) =>
      _route(
        () => _supabase.categoryBreakdown(
          from: from,
          to: to,
          accountId: accountId,
        ),
        () => _drift.categoryBreakdown(
          from: from,
          to: to,
          accountId: accountId,
        ),
      );

  @override
  Future<double> categoryExpenseTotalBetween({
    required String categoryId,
    required DateTime from,
    required DateTime to,
    String? accountId,
  }) =>
      _route(
        () => _supabase.categoryExpenseTotalBetween(
          categoryId: categoryId,
          from: from,
          to: to,
          accountId: accountId,
        ),
        () => _drift.categoryExpenseTotalBetween(
          categoryId: categoryId,
          from: from,
          to: to,
          accountId: accountId,
        ),
      );

  @override
  Future<List<MerchantSpend>> merchantBreakdown({
    required DateTime from,
    required DateTime to,
    int limit = 3,
    String? accountId,
  }) =>
      _route(
        () => _supabase.merchantBreakdown(
          from: from,
          to: to,
          limit: limit,
          accountId: accountId,
        ),
        () => _drift.merchantBreakdown(
          from: from,
          to: to,
          limit: limit,
          accountId: accountId,
        ),
      );

  @override
  Future<List<RecurringCandidate>> recurringCandidates({String? accountId}) =>
      _route(
        () => _supabase.recurringCandidates(accountId: accountId),
        () => _drift.recurringCandidates(accountId: accountId),
      );

  @override
  Future<List<CardSummary>> getCardSummaries() =>
      _route(_supabase.getCardSummaries, _drift.getCardSummaries);
}
