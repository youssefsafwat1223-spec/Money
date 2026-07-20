import '../entities/engagement_entities.dart';
import '../entities/supporting_entities.dart';
import '../repositories/gamification_repository.dart';
import '../repositories/transaction_repository.dart';
import '../repositories/user_settings_repository.dart';

class RecordEngagementUseCase {
  RecordEngagementUseCase({
    required GamificationRepository gamificationRepository,
    required TransactionRepository transactionRepository,
    required UserSettingsRepository userSettingsRepository,
    this.onUpdate,
  }) : _gamificationRepository = gamificationRepository;

  final GamificationRepository _gamificationRepository;
  final void Function(EngagementUpdate update)? onUpdate;

  Future<EngagementUpdate> call({
    required EngagementAction action,
    DateTime? occurredAt,
    double? goalProgressAfter,
    double? savedThisMonth,
  }) async {
    final streak = await _gamificationRepository.getStreak();
    final xpLevel = await _gamificationRepository.getXpLevel();

    final update = EngagementUpdate(
      streak: streak,
      xpLevel: xpLevel,
      unlockedAchievements: [],
      celebrations: [],
    );
    onUpdate?.call(update);
    return update;
  }

  Future<List<AchievementEntity>> evaluatePassiveBadges({
    DateTime? now,
  }) async {
    return [];
  }
}
