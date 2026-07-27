import '../../domain/entities/goal_entity.dart';
import '../../domain/repositories/goal_repository.dart';

/// S5: توجيه المرحلة-A أُزيل — غلاف رفيع يفوّض إلى Drift. المزامنة خلفية فقط.
class RoutedGoalRepository implements GoalRepository {
  const RoutedGoalRepository({required GoalRepository drift}) : _drift = drift;

  final GoalRepository _drift;

  @override
  Future<GoalContributionEntity> addContribution(
          GoalContributionEntity value) =>
      _drift.addContribution(value);
  @override
  Future<int> countAll() => _drift.countAll();
  @override
  Future<void> delete(String id) => _drift.delete(id);
  @override
  Future<List<GoalEntity>> getAll() => _drift.getAll();
  @override
  Future<GoalEntity?> getById(String id) => _drift.getById(id);
  @override
  Future<List<GoalContributionEntity>> getContributions(String goalId) =>
      _drift.getContributions(goalId);
  @override
  Future<GoalEntity> save(GoalEntity goal) => _drift.save(goal);
}
