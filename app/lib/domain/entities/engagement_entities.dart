import 'budget_entity.dart';
import 'goal_entity.dart';
import 'supporting_entities.dart';

enum BudgetHealth { safe, warning, over }

class BudgetProgressEntry {
  const BudgetProgressEntry({
    required this.budget,
    required this.spent,
    required this.remaining,
    required this.ratio,
    required this.health,
    required this.periodStart,
    required this.periodEnd,
  });

  final BudgetEntity budget;
  final double spent;
  final double remaining;
  final double ratio;
  final BudgetHealth health;
  final DateTime periodStart;
  final DateTime periodEnd;
}

enum BudgetAlertKind { warning80, over100 }

class BudgetAlertTrigger {
  const BudgetAlertTrigger({
    required this.budget,
    required this.progress,
    required this.kind,
  });

  final BudgetEntity budget;
  final BudgetProgressEntry progress;
  final BudgetAlertKind kind;
}

class BudgetProgressSnapshot {
  const BudgetProgressSnapshot({
    required this.entries,
    required this.alerts,
  });

  final List<BudgetProgressEntry> entries;
  final List<BudgetAlertTrigger> alerts;
}

class GoalDetailsEntity {
  const GoalDetailsEntity({
    required this.goal,
    required this.contributions,
    required this.progress,
    required this.remainingAmount,
    required this.recommendedDailyAmount,
    required this.recommendedWeeklyAmount,
    required this.daysRemaining,
  });

  final GoalEntity goal;
  final List<GoalContributionEntity> contributions;
  final double progress;
  final double remainingAmount;
  final double recommendedDailyAmount;
  final double recommendedWeeklyAmount;
  final int? daysRemaining;
}

enum NotificationType {
  captureReview,
  captureLight,
  budgetWarning,
  budgetOver,
  achievements,
  streakReminder,
  weeklyReport,
  subscriptionReminder,
  goalMilestone,
}

class NotificationPreferences {
  const NotificationPreferences({
    this.captureReview = true,
    this.captureLight = true,
    this.budgetWarning = true,
    this.budgetOver = true,
    this.achievements = true,
    this.streakReminder = true,
    this.weeklyReport = true,
    this.subscriptionReminder = true,
    this.goalMilestone = true,
    this.quietHoursStartHour = 23,
    this.quietHoursEndHour = 8,
    this.lastDailyBudgetRewardDate,
    this.lastSaved500MonthKey,
    this.lastRestaurantReductionMonthKey,
    this.lastMonthWithoutOverrunKey,
    this.notifiedGoalMilestones = const {},
  });

  final bool captureReview;
  final bool captureLight;
  final bool budgetWarning;
  final bool budgetOver;
  final bool achievements;
  final bool streakReminder;
  final bool weeklyReport;
  final bool subscriptionReminder;
  final bool goalMilestone;
  final int quietHoursStartHour;
  final int quietHoursEndHour;
  final String? lastDailyBudgetRewardDate;
  final String? lastSaved500MonthKey;
  final String? lastRestaurantReductionMonthKey;
  final String? lastMonthWithoutOverrunKey;
  final Map<String, int> notifiedGoalMilestones;

  bool isEnabled(NotificationType type) {
    switch (type) {
      case NotificationType.captureReview:
        return captureReview;
      case NotificationType.captureLight:
        return captureLight;
      case NotificationType.budgetWarning:
        return budgetWarning;
      case NotificationType.budgetOver:
        return budgetOver;
      case NotificationType.achievements:
        return achievements;
      case NotificationType.streakReminder:
        return streakReminder;
      case NotificationType.weeklyReport:
        return weeklyReport;
      case NotificationType.subscriptionReminder:
        return subscriptionReminder;
      case NotificationType.goalMilestone:
        return goalMilestone;
    }
  }

  NotificationPreferences copyWith({
    bool? captureReview,
    bool? captureLight,
    bool? budgetWarning,
    bool? budgetOver,
    bool? achievements,
    bool? streakReminder,
    bool? weeklyReport,
    bool? subscriptionReminder,
    bool? goalMilestone,
    int? quietHoursStartHour,
    int? quietHoursEndHour,
    String? lastDailyBudgetRewardDate,
    String? lastSaved500MonthKey,
    String? lastRestaurantReductionMonthKey,
    String? lastMonthWithoutOverrunKey,
    Map<String, int>? notifiedGoalMilestones,
  }) {
    return NotificationPreferences(
      captureReview: captureReview ?? this.captureReview,
      captureLight: captureLight ?? this.captureLight,
      budgetWarning: budgetWarning ?? this.budgetWarning,
      budgetOver: budgetOver ?? this.budgetOver,
      achievements: achievements ?? this.achievements,
      streakReminder: streakReminder ?? this.streakReminder,
      weeklyReport: weeklyReport ?? this.weeklyReport,
      subscriptionReminder: subscriptionReminder ?? this.subscriptionReminder,
      goalMilestone: goalMilestone ?? this.goalMilestone,
      quietHoursStartHour: quietHoursStartHour ?? this.quietHoursStartHour,
      quietHoursEndHour: quietHoursEndHour ?? this.quietHoursEndHour,
      lastDailyBudgetRewardDate:
          lastDailyBudgetRewardDate ?? this.lastDailyBudgetRewardDate,
      lastSaved500MonthKey: lastSaved500MonthKey ?? this.lastSaved500MonthKey,
      lastRestaurantReductionMonthKey: lastRestaurantReductionMonthKey ??
          this.lastRestaurantReductionMonthKey,
      lastMonthWithoutOverrunKey:
          lastMonthWithoutOverrunKey ?? this.lastMonthWithoutOverrunKey,
      notifiedGoalMilestones:
          notifiedGoalMilestones ?? this.notifiedGoalMilestones,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'captureReview': captureReview,
      'captureLight': captureLight,
      'budgetWarning': budgetWarning,
      'budgetOver': budgetOver,
      'achievements': achievements,
      'streakReminder': streakReminder,
      'weeklyReport': weeklyReport,
      'subscriptionReminder': subscriptionReminder,
      'goalMilestone': goalMilestone,
      'quietHoursStartHour': quietHoursStartHour,
      'quietHoursEndHour': quietHoursEndHour,
      'lastDailyBudgetRewardDate': lastDailyBudgetRewardDate,
      'lastSaved500MonthKey': lastSaved500MonthKey,
      'lastRestaurantReductionMonthKey': lastRestaurantReductionMonthKey,
      'lastMonthWithoutOverrunKey': lastMonthWithoutOverrunKey,
      'notifiedGoalMilestones': notifiedGoalMilestones,
    };
  }

  static NotificationPreferences fromJson(Map<String, dynamic>? json) {
    if (json == null) {
      return const NotificationPreferences();
    }
    return NotificationPreferences(
      captureReview: json['captureReview'] as bool? ?? true,
      captureLight: json['captureLight'] as bool? ?? true,
      budgetWarning: json['budgetWarning'] as bool? ?? true,
      budgetOver: json['budgetOver'] as bool? ?? true,
      achievements: json['achievements'] as bool? ?? true,
      streakReminder: json['streakReminder'] as bool? ?? true,
      weeklyReport: json['weeklyReport'] as bool? ?? true,
      subscriptionReminder: json['subscriptionReminder'] as bool? ?? true,
      goalMilestone: json['goalMilestone'] as bool? ?? true,
      quietHoursStartHour: json['quietHoursStartHour'] as int? ?? 23,
      quietHoursEndHour: json['quietHoursEndHour'] as int? ?? 8,
      lastDailyBudgetRewardDate: json['lastDailyBudgetRewardDate'] as String?,
      lastSaved500MonthKey: json['lastSaved500MonthKey'] as String?,
      lastRestaurantReductionMonthKey:
          json['lastRestaurantReductionMonthKey'] as String?,
      lastMonthWithoutOverrunKey: json['lastMonthWithoutOverrunKey'] as String?,
      notifiedGoalMilestones: _readGoalMilestones(
        json['notifiedGoalMilestones'],
      ),
    );
  }

  static Map<String, int> _readGoalMilestones(Object? value) {
    if (value is! Map) return const {};
    return value.map(
      (key, milestone) => MapEntry(
        key.toString(),
        milestone is int ? milestone : int.tryParse('$milestone') ?? 0,
      ),
    );
  }
}

enum EngagementAction {
  transactionAdded,
  transactionConfirmed,
  categoryCorrected,
  firstBudgetCreated,
  goalCreated,
  goalMilestone,
  dailyBudgetKept,
}

enum CelebrationKind { badgeUnlocked, levelUp, streakMilestone, goalMilestone }

class CelebrationEvent {
  const CelebrationEvent({
    required this.kind,
    required this.title,
    required this.message,
  });

  final CelebrationKind kind;
  final String title;
  final String message;
}

class EngagementUpdate {
  const EngagementUpdate({
    required this.streak,
    required this.xpLevel,
    required this.unlockedAchievements,
    required this.celebrations,
  });

  final StreakEntity streak;
  final XpLevelEntity xpLevel;
  final List<AchievementEntity> unlockedAchievements;
  final List<CelebrationEvent> celebrations;
}
