import '../entities/goal_entity.dart';

abstract class GoalRepository {
  Future<GoalEntity> save(GoalEntity goal);
  Future<List<GoalEntity>> getAll();
  Future<GoalEntity?> getById(String id);
  Future<int> countAll();
  Future<List<GoalContributionEntity>> getContributions(String goalId);
  Future<void> delete(String id);
  Future<GoalContributionEntity> addContribution(
      GoalContributionEntity contribution);
}
