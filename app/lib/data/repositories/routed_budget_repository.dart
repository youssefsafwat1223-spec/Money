import '../../data/catalog/feature_flag_service.dart';
import '../../data/db/app_database.dart';
import '../../data/db/financial_cache_health.dart';
import '../../domain/entities/budget_entity.dart';
import '../../domain/repositories/budget_repository.dart';

class RoutedBudgetRepository implements BudgetRepository {
  const RoutedBudgetRepository({
    required BudgetRepository drift,
    required BudgetRepository supabase,
    required FeatureFlagService Function() flags,
    required AppDatabase db,
  })  : _drift = drift,
        _supabase = supabase,
        _flags = flags,
        _db = db;

  final BudgetRepository _drift;
  final BudgetRepository _supabase;
  final FeatureFlagService Function() _flags;
  final AppDatabase _db;
  bool get _useSupabase => _flags().getBool('budgets_supabase_primary');
  Future<T> _route<T>(
    Future<T> Function() supabase,
    Future<T> Function() drift,
  ) =>
      routeFinancialOperation(
        db: _db,
        entityType: budgetsCacheEntityType,
        useSupabase: _useSupabase,
        supabase: supabase,
        drift: drift,
      );

  @override
  Future<int> countActive() =>
      _route(_supabase.countActive, _drift.countActive);
  @override
  Future<void> delete(String id) =>
      _route(() => _supabase.delete(id), () => _drift.delete(id));
  @override
  Future<List<BudgetEntity>> getAll() =>
      _route(_supabase.getAll, _drift.getAll);
  @override
  Future<BudgetEntity?> getById(String id) =>
      _route(() => _supabase.getById(id), () => _drift.getById(id));
  @override
  Future<BudgetEntity> save(BudgetEntity budget) =>
      _route(() => _supabase.save(budget), () => _drift.save(budget));
}
