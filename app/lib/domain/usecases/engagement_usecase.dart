import '../../core/utils/riyadh_time.dart';
import '../entities/achievement_catalog.dart';
import '../entities/engagement_entities.dart';
import '../entities/supporting_entities.dart';
import '../repositories/gamification_repository.dart';
import '../repositories/transaction_repository.dart';
import '../repositories/user_settings_repository.dart';
import 'gamification_rules.dart';
import 'user_settings_usecases.dart';

class RecordEngagementUseCase {
  RecordEngagementUseCase({
    required GamificationRepository gamificationRepository,
    required TransactionRepository transactionRepository,
    required UserSettingsRepository userSettingsRepository,
    this.onUpdate,
    StreakEngine? streakEngine,
    XpLevelEngine? xpLevelEngine,
    BadgeEngine? badgeEngine,
  })  : _gamificationRepository = gamificationRepository,
        _transactionRepository = transactionRepository,
        _loadNotificationPreferences =
            LoadNotificationPreferencesUseCase(userSettingsRepository),
        _saveNotificationPreferences =
            SaveNotificationPreferencesUseCase(userSettingsRepository),
        _streakEngine = streakEngine ?? const StreakEngine(),
        _xpLevelEngine = xpLevelEngine ?? const XpLevelEngine(),
        _badgeEngine = badgeEngine ?? const BadgeEngine();

  final GamificationRepository _gamificationRepository;
  final TransactionRepository _transactionRepository;
  final LoadNotificationPreferencesUseCase _loadNotificationPreferences;
  final SaveNotificationPreferencesUseCase _saveNotificationPreferences;
  final void Function(EngagementUpdate update)? onUpdate;
  final StreakEngine _streakEngine;
  final XpLevelEngine _xpLevelEngine;
  final BadgeEngine _badgeEngine;

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
