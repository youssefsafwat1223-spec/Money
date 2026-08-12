import '../entities/plan_entity.dart';
import '../entities/transaction_entity.dart';
import '../finance/money.dart';

abstract class PlanRepository {
  Future<List<PlanEntity>> getAll();
  Future<PlanEntity?> getById(String id);
  Future<PlanEntity> save(PlanEntity plan);
  Future<void> delete(String id);

  /// Total confirmed spending that falls inside the plan's date range and comes
  /// from its chosen accounts/cards. When no account/card is chosen, all spend
  /// in the range counts.
  Future<Money> spentForPlan(PlanEntity plan);

  Future<List<TransactionEntity>> transactionsForPlan(PlanEntity plan);

  Future<void> linkTransactionToPlan({
    required String planId,
    required String transactionId,
  });

  Future<void> unlinkTransactionFromPlan({
    required String planId,
    required String transactionId,
  });
}
