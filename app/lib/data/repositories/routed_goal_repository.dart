import '../../data/catalog/feature_flag_service.dart';
import '../../data/db/app_database.dart';
import '../../data/db/financial_cache_health.dart';
import '../../domain/entities/goal_entity.dart';
import '../../domain/repositories/goal_repository.dart';

class RoutedGoalRepository implements GoalRepository {
  const RoutedGoalRepository({
    required GoalRepository drift,
    required GoalRepository supabase,
    required FeatureFlagService Function() flags,
    required AppDatabase db,
  })  : _drift = drift,
        _supabase = supabase,
        _flags = flags,
        _db = db;

  final GoalRepository _drift;
  final GoalRepository _supabase;
  final FeatureFlagService Function() _flags;
  final AppDatabase _db;
  bool get _useSupabase => _flags().getBool('goals_supabase_primary');
  Future<T> _route<T>(
    Future<T> Function() supabase,
    Future<T> Function() drift,
  ) =>
      routeFinancialOperation(
        db: _db,
        entityType: goalsCacheEntityType,
        useSupabase: _useSupabase,
        supabase: supabase,
        drift: drift,
      );

  @override
  Future<GoalContributionEntity> addContribution(
          GoalContributionEntity value) =>
      _route(
        () => _supabase.addContribution(value),
        () => _drift.addContribution(value),
      );
  @override
  Future<int> countAll() => _route(_supabase.countAll, _drift.countAll);
  @override
  Future<void> delete(String id) =>
      _route(() => _supabase.delete(id), () => _drift.delete(id));
  @override
  Future<List<GoalEntity>> getAll() => _route(_supabase.getAll, _drift.getAll);
  @override
  Future<GoalEntity?> getById(String id) =>
      _route(() => _supabase.getById(id), () => _drift.getById(id));
  @override
  Future<List<GoalContributionEntity>> getContributions(String goalId) =>
      _route(
        () => _supabase.getContributions(goalId),
        () => _drift.getContributions(goalId),
      );
  @override
  Future<GoalEntity> save(GoalEntity goal) =>
      _route(() => _supabase.save(goal), () => _drift.save(goal));
}
