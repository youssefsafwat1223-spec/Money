import '../entities/engagement_entities.dart';
import '../repositories/goal_repository.dart';

class GoalDetailsUseCase {
  GoalDetailsUseCase(this._goalRepository);

  final GoalRepository _goalRepository;

  Future<GoalDetailsEntity?> call(String goalId, {DateTime? now}) async {
    final goal = await _goalRepository.getById(goalId);
    if (goal == null) {
      return null;
    }
    final contributions = await _goalRepository.getContributions(goalId);
    final current = now ?? DateTime.now().toUtc();
    final remainingAmount = (goal.targetAmount - goal.savedAmount).clamp(
      0,
      double.infinity,
    );
    final progress =
        goal.targetAmount == 0 ? 0.0 : goal.savedAmount / goal.targetAmount;
    final daysRemaining =
        goal.deadline?.difference(current).inDays.clamp(0, 1000000);
    final recommendedDaily = daysRemaining == null || daysRemaining == 0
        ? remainingAmount.toDouble()
        : remainingAmount / daysRemaining;
    return GoalDetailsEntity(
      goal: goal,
      contributions: contributions,
      progress: progress.clamp(0, 1),
      remainingAmount: remainingAmount.toDouble(),
      recommendedDailyAmount: recommendedDaily,
      recommendedWeeklyAmount: recommendedDaily * 7,
      daysRemaining: daysRemaining,
    );
  }
}
