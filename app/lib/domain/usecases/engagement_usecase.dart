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
    final eventTime = occurredAt ?? DateTime.now().toUtc();
    var streak = await _gamificationRepository.getStreak();
    var xpLevel = await _gamificationRepository.getXpLevel();
    final unlocked = <AchievementEntity>[];
    final celebrations = <CelebrationEvent>[];

    if (action == EngagementAction.transactionAdded ||
        action == EngagementAction.transactionConfirmed) {
      final streakUpdate = _streakEngine.recordActivity(
        current: streak,
        occurredAt: eventTime,
        weeklyFreezeAllowance: 1,
        dayGap: RiyadhTime.dayGap,
        isSameWeek: RiyadhTime.isSameWeek,
      );
      streak = await _gamificationRepository.saveStreak(streakUpdate.streak);
      if (streakUpdate.reachedMilestone != null) {
        final reward = switch (streakUpdate.reachedMilestone!) {
          7 => 25,
          30 => 100,
          100 => 300,
          _ => 0,
        };
        final rewardResult = _xpLevelEngine.addXp(xpLevel, reward);
        xpLevel = await _gamificationRepository.saveXpLevel(
          rewardResult.xpLevel,
        );
        celebrations.add(
          CelebrationEvent(
            kind: CelebrationKind.streakMilestone,
            title: 'سلسلة جديدة',
            message: 'وصلت إلى ${streakUpdate.reachedMilestone} أيام متواصلة.',
          ),
        );
      }
    }

    final xpResult = _xpLevelEngine.addXp(xpLevel, _xpFor(action));
    xpLevel = await _gamificationRepository.saveXpLevel(xpResult.xpLevel);
    if (xpResult.didLevelUp) {
      celebrations.add(
        CelebrationEvent(
          kind: CelebrationKind.levelUp,
          title: 'مستوى جديد',
          message: _levelLabel(xpLevel.levelKey),
        ),
      );
    }

    final badgeDefinitions = _badgeEngine.evaluate(
      action: action,
      streakValue: streak.currentStreak,
      savedThisMonth: savedThisMonth,
      goalProgressAfter: goalProgressAfter,
    );
    for (final definition in badgeDefinitions) {
      final achievement = await _unlockAchievement(definition.key);
      if (achievement != null) {
        unlocked.add(achievement);
        celebrations.add(
          CelebrationEvent(
            kind: CelebrationKind.badgeUnlocked,
            title: 'شارة جديدة',
            message: achievement.nameAr,
          ),
        );
      }
    }

    final update = EngagementUpdate(
      streak: streak,
      xpLevel: xpLevel,
      unlockedAchievements: unlocked,
      celebrations: celebrations,
    );
    onUpdate?.call(update);
    return update;
  }

  Future<List<AchievementEntity>> evaluatePassiveBadges({
    DateTime? now,
  }) async {
    final current = now ?? DateTime.now().toUtc();
    final preferences = await _loadNotificationPreferences();
    final unlocked = <AchievementEntity>[];
    final monthKey = _monthKey(current);

    final monthStart = RiyadhTime.startOfMonth(current);
    final prevMonthStart = RiyadhTime.startOfMonth(
      monthStart.subtract(const Duration(days: 1)),
    );
    final elapsed = current.difference(monthStart);
    final prevSamePoint = prevMonthStart.add(elapsed);
    final thisMonthExpenses = await _transactionRepository.expenseTotalBetween(
      from: monthStart,
      to: current,
    );
    final prevMonthExpenses = await _transactionRepository.expenseTotalBetween(
      from: prevMonthStart,
      to: prevSamePoint,
    );
    final savedThisMonth = prevMonthExpenses - thisMonthExpenses;
    if (savedThisMonth >= 500 &&
        preferences.lastSaved500MonthKey != monthKey) {
      final achievement = await _unlockAchievement(AchievementCatalog.saved500.key);
      if (achievement != null) {
        unlocked.add(achievement);
      }
      await _saveNotificationPreferences(
        preferences.copyWith(lastSaved500MonthKey: monthKey),
      );
    }

    return unlocked;
  }

  int _xpFor(EngagementAction action) {
    switch (action) {
      case EngagementAction.transactionAdded:
        return 0;
      case EngagementAction.transactionConfirmed:
        return 5;
      case EngagementAction.categoryCorrected:
        return 3;
      case EngagementAction.firstBudgetCreated:
        return 20;
      case EngagementAction.goalCreated:
        return 15;
      case EngagementAction.goalMilestone:
        return 50;
      case EngagementAction.dailyBudgetKept:
        return 10;
    }
  }

  String _levelLabel(String levelKey) {
    switch (levelKey) {
      case 'organized':
        return 'منظّم';
      case 'smart_saver':
        return 'موفّر ذكي';
      case 'financial_expert':
        return 'خبير مالي';
      case 'saving_legend':
        return 'أسطورة الادخار';
      case 'beginner':
      default:
        return 'مبتدئ';
    }
  }

  Future<AchievementEntity?> _unlockAchievement(String key) async {
    final achievement = await _gamificationRepository.getAchievementByKey(key);
    if (achievement == null || achievement.unlockedAt != null) {
      return null;
    }
    final updated = achievement.copyWith(
      unlockedAt: DateTime.now().toUtc(),
      progress: 1,
    );
    return _gamificationRepository.saveAchievement(updated);
  }

  String _monthKey(DateTime dateTime) {
    final riyadh = RiyadhTime.toRiyadh(dateTime);
    final month = riyadh.month.toString().padLeft(2, '0');
    return '${riyadh.year}-$month';
  }
}
