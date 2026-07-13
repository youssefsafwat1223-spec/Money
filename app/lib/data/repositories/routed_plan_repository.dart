import '../../data/catalog/feature_flag_service.dart';
import '../../data/db/app_database.dart';
import '../../data/db/financial_cache_health.dart';
import '../../domain/entities/plan_entity.dart';
import '../../domain/entities/transaction_entity.dart';
import '../../domain/repositories/plan_repository.dart';

class RoutedPlanRepository implements PlanRepository {
  const RoutedPlanRepository({
    required PlanRepository drift,
    required PlanRepository supabase,
    required FeatureFlagService Function() flags,
    required AppDatabase db,
  })  : _drift = drift,
        _supabase = supabase,
        _flags = flags,
        _db = db;

  final PlanRepository _drift;
  final PlanRepository _supabase;
  final FeatureFlagService Function() _flags;
  final AppDatabase _db;
  bool get _useSupabase => _flags().getBool('plans_supabase_primary');
  Future<T> _route<T>(
    Future<T> Function() supabase,
    Future<T> Function() drift,
  ) =>
      routeFinancialOperation(
        db: _db,
        entityType: plansCacheEntityType,
        useSupabase: _useSupabase,
        supabase: supabase,
        drift: drift,
      );

  @override
  Future<void> delete(String id) =>
      _route(() => _supabase.delete(id), () => _drift.delete(id));
  @override
  Future<List<PlanEntity>> getAll() => _route(_supabase.getAll, _drift.getAll);
  @override
  Future<PlanEntity?> getById(String id) =>
      _route(() => _supabase.getById(id), () => _drift.getById(id));
  @override
  Future<void> linkTransactionToPlan(
          {required String planId, required String transactionId}) =>
      _route(
        () => _supabase.linkTransactionToPlan(
          planId: planId,
          transactionId: transactionId,
        ),
        () => _drift.linkTransactionToPlan(
          planId: planId,
          transactionId: transactionId,
        ),
      );
  @override
  Future<PlanEntity> save(PlanEntity plan) =>
      _route(() => _supabase.save(plan), () => _drift.save(plan));
  @override
  Future<double> spentForPlan(PlanEntity plan) => _route(
        () => _supabase.spentForPlan(plan),
        () => _drift.spentForPlan(plan),
      );
  @override
  Future<List<TransactionEntity>> transactionsForPlan(PlanEntity plan) =>
      _route(
        () => _supabase.transactionsForPlan(plan),
        () => _drift.transactionsForPlan(plan),
      );
  @override
  Future<void> unlinkTransactionFromPlan(
          {required String planId, required String transactionId}) =>
      _route(
        () => _supabase.unlinkTransactionFromPlan(
          planId: planId,
          transactionId: transactionId,
        ),
        () => _drift.unlinkTransactionFromPlan(
          planId: planId,
          transactionId: transactionId,
        ),
      );
}
