import '../entities/goal_entity.dart';
import '../repositories/goal_repository.dart';
import 'engagement_usecase.dart';
import '../entities/engagement_entities.dart';

class SaveGoalUseCase {
  SaveGoalUseCase(
    this._goalRepository, {
    this.recordEngagementUseCase,
  });

  final GoalRepository _goalRepository;
  final RecordEngagementUseCase? recordEngagementUseCase;

  Future<GoalEntity> call(GoalEntity goal) async {
    final existing = await _goalRepository.getById(goal.id);
    final saved = await _goalRepository.save(goal);
    if (existing == null && recordEngagementUseCase != null) {
      await recordEngagementUseCase!(
        action: EngagementAction.goalCreated,
        occurredAt: saved.createdAt,
      );
    }
    return saved;
  }
}

class DeleteGoalUseCase {
  DeleteGoalUseCase(this._goalRepository);

  final GoalRepository _goalRepository;

  Future<void> call(String goalId) {
    return _goalRepository.delete(goalId);
  }
}

class AddGoalContributionUseCase {
  AddGoalContributionUseCase(
    this._goalRepository, {
    this.recordEngagementUseCase,
  });

  final GoalRepository _goalRepository;
  final RecordEngagementUseCase? recordEngagementUseCase;

  Future<GoalContributionEntity> call(GoalContributionEntity contribution) async {
    final goal = await _goalRepository.getById(contribution.goalId);
    final beforeProgress = goal == null || goal.targetAmount == 0
        ? 0.0
        : goal.savedAmount / goal.targetAmount;
    final saved = await _goalRepository.addContribution(contribution);
    final updatedGoal = await _goalRepository.getById(contribution.goalId);
    final afterProgress = updatedGoal == null || updatedGoal.targetAmount == 0
        ? 0.0
        : updatedGoal.savedAmount / updatedGoal.targetAmount;
    if (recordEngagementUseCase != null &&
        _crossedMilestone(beforeProgress, afterProgress)) {
      await recordEngagementUseCase!(
        action: EngagementAction.goalMilestone,
        occurredAt: contribution.createdAt,
        goalProgressAfter: afterProgress,
      );
    }
    return saved;
  }

  bool _crossedMilestone(double before, double after) {
    const checkpoints = [0.25, 0.5, 0.75, 1.0];
    return checkpoints.any((checkpoint) => before < checkpoint && after >= checkpoint);
  }
}
