import '../entities/engagement_entities.dart';
import '../finance/money.dart';
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
    final rawRemaining = goal.targetMoney - goal.savedMoney;
    final zero = Money.zero(goal.currency);
    final remainingAmount =
        rawRemaining.compareTo(zero) < 0 ? zero : rawRemaining;
    final progress = goal.targetMoney.isZero
        ? 0.0
        : goal.savedMoney.toDouble() / goal.targetMoney.toDouble();
    final daysRemaining =
        goal.deadline?.difference(current).inDays.clamp(0, 1000000);
    final recommendedDaily = daysRemaining == null || daysRemaining == 0
        ? remainingAmount
        : remainingAmount.applyRate(
            rateNumerator: BigInt.one,
            rateDenominator: BigInt.from(daysRemaining),
          );
    final recommendedWeekly = daysRemaining == null || daysRemaining == 0
        ? remainingAmount
        : remainingAmount.applyRate(
            rateNumerator: BigInt.from(7),
            rateDenominator: BigInt.from(daysRemaining),
          );
    return GoalDetailsEntity(
      goal: goal,
      contributions: contributions,
      progress: progress.clamp(0, 1),
      remainingAmount: remainingAmount,
      recommendedDailyAmount: recommendedDaily,
      recommendedWeeklyAmount: recommendedWeekly,
      daysRemaining: daysRemaining,
    );
  }
}
