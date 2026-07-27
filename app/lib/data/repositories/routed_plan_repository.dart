import '../../domain/entities/plan_entity.dart';
import '../../domain/entities/transaction_entity.dart';
import '../../domain/repositories/plan_repository.dart';

/// S5: توجيه المرحلة-A أُزيل — غلاف رفيع يفوّض إلى Drift. المزامنة خلفية فقط.
class RoutedPlanRepository implements PlanRepository {
  const RoutedPlanRepository({required PlanRepository drift}) : _drift = drift;

  final PlanRepository _drift;

  @override
  Future<void> delete(String id) => _drift.delete(id);
  @override
  Future<List<PlanEntity>> getAll() => _drift.getAll();
  @override
  Future<PlanEntity?> getById(String id) => _drift.getById(id);
  @override
  Future<void> linkTransactionToPlan(
          {required String planId, required String transactionId}) =>
      _drift.linkTransactionToPlan(
          planId: planId, transactionId: transactionId);
  @override
  Future<PlanEntity> save(PlanEntity plan) => _drift.save(plan);
  @override
  Future<double> spentForPlan(PlanEntity plan) => _drift.spentForPlan(plan);
  @override
  Future<List<TransactionEntity>> transactionsForPlan(PlanEntity plan) =>
      _drift.transactionsForPlan(plan);
  @override
  Future<void> unlinkTransactionFromPlan(
          {required String planId, required String transactionId}) =>
      _drift.unlinkTransactionFromPlan(
          planId: planId, transactionId: transactionId);
}
