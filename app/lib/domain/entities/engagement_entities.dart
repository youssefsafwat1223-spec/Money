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
  marketing,
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
    this.marketingMessages = true,
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
    this.inboxState = const NotificationInboxState(),
  });

  final bool captureReview;
  final bool captureLight;
  final bool marketingMessages;
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
  final NotificationInboxState inboxState;

  bool isEnabled(NotificationType type) {
    switch (type) {
      case NotificationType.captureReview:
        return captureReview;
      case NotificationType.captureLight:
        return captureLight;
      case NotificationType.marketing:
        return marketingMessages;
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
    bool? marketingMessages,
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
    NotificationInboxState? inboxState,
  }) {
    return NotificationPreferences(
      captureReview: captureReview ?? this.captureReview,
      captureLight: captureLight ?? this.captureLight,
      marketingMessages: marketingMessages ?? this.marketingMessages,
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
      inboxState: inboxState ?? this.inboxState,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'captureReview': captureReview,
      'captureLight': captureLight,
      'marketingMessages': marketingMessages,
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
      'notificationInboxState': inboxState.toJson(),
    };
  }

  static NotificationPreferences fromJson(Map<String, dynamic>? json) {
    if (json == null) {
      return const NotificationPreferences();
    }
    return NotificationPreferences(
      captureReview: json['captureReview'] as bool? ?? true,
      captureLight: json['captureLight'] as bool? ?? true,
      marketingMessages: json['marketingMessages'] as bool? ?? true,
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
      inboxState: NotificationInboxState.fromJson(
        json['notificationInboxState'] as Map<String, dynamic>?,
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

class NotificationInboxState {
  const NotificationInboxState({
    this.firstSeenAt,
    this.lastMarketingNotificationAt,
    this.sentCampaignAt = const {},
    this.impressionCounts = const {},
    this.dismissedCampaignIds = const {},
    this.sentJourneyIds = const {},
    this.history = const [],
  });

  final DateTime? firstSeenAt;
  final DateTime? lastMarketingNotificationAt;
  final Map<String, DateTime> sentCampaignAt;
  final Map<String, int> impressionCounts;
  final Set<String> dismissedCampaignIds;
  final Set<String> sentJourneyIds;
  final List<NotificationHistoryEntry> history;

  bool hasDismissed(String id) => dismissedCampaignIds.contains(id);

  bool hasSentJourney(String id) => sentJourneyIds.contains(id);

  int impressionsFor(String id) => impressionCounts[id] ?? 0;

  DateTime? lastSentFor(String id) => sentCampaignAt[id];

  NotificationInboxState copyWith({
    DateTime? firstSeenAt,
    bool clearFirstSeenAt = false,
    DateTime? lastMarketingNotificationAt,
    bool clearLastMarketingNotificationAt = false,
    Map<String, DateTime>? sentCampaignAt,
    Map<String, int>? impressionCounts,
    Set<String>? dismissedCampaignIds,
    Set<String>? sentJourneyIds,
    List<NotificationHistoryEntry>? history,
  }) {
    return NotificationInboxState(
      firstSeenAt: clearFirstSeenAt ? null : firstSeenAt ?? this.firstSeenAt,
      lastMarketingNotificationAt: clearLastMarketingNotificationAt
          ? null
          : lastMarketingNotificationAt ?? this.lastMarketingNotificationAt,
      sentCampaignAt: sentCampaignAt ?? this.sentCampaignAt,
      impressionCounts: impressionCounts ?? this.impressionCounts,
      dismissedCampaignIds: dismissedCampaignIds ?? this.dismissedCampaignIds,
      sentJourneyIds: sentJourneyIds ?? this.sentJourneyIds,
      history: history ?? this.history,
    );
  }

  NotificationInboxState markMarketingSent(String id, DateTime sentAt) {
    final sent = Map<String, DateTime>.from(sentCampaignAt);
    sent[id] = sentAt.toUtc();
    return copyWith(
      lastMarketingNotificationAt: sentAt.toUtc(),
      sentCampaignAt: sent,
    );
  }

  NotificationInboxState markJourneySent(String id, DateTime sentAt) {
    final sent = Map<String, DateTime>.from(sentCampaignAt);
    sent[id] = sentAt.toUtc();
    return copyWith(
      lastMarketingNotificationAt: sentAt.toUtc(),
      sentCampaignAt: sent,
      sentJourneyIds: {...sentJourneyIds, id},
    );
  }

  NotificationInboxState addHistory(NotificationHistoryEntry entry) {
    final next = [
      entry,
      ...history.where((item) => item.id != entry.id),
    ];
    return copyWith(history: next.take(80).toList());
  }

  NotificationInboxState markImpression(String id) {
    final counts = Map<String, int>.from(impressionCounts);
    counts[id] = (counts[id] ?? 0) + 1;
    return copyWith(impressionCounts: counts);
  }

  NotificationInboxState markDismissed(String id) {
    return copyWith(dismissedCampaignIds: {...dismissedCampaignIds, id});
  }

  Map<String, dynamic> toJson() {
    return {
      'firstSeenAt': firstSeenAt?.toUtc().toIso8601String(),
      'lastMarketingNotificationAt':
          lastMarketingNotificationAt?.toUtc().toIso8601String(),
      'sentCampaignAt': sentCampaignAt.map(
        (key, value) => MapEntry(key, value.toUtc().toIso8601String()),
      ),
      'impressionCounts': impressionCounts,
      'dismissedCampaignIds': dismissedCampaignIds.toList(),
      'sentJourneyIds': sentJourneyIds.toList(),
      'history': history.map((entry) => entry.toJson()).toList(),
    };
  }

  static NotificationInboxState fromJson(Map<String, dynamic>? json) {
    if (json == null) return const NotificationInboxState();
    return NotificationInboxState(
      firstSeenAt: _readDate(json['firstSeenAt']),
      lastMarketingNotificationAt:
          _readDate(json['lastMarketingNotificationAt']),
      sentCampaignAt: _readDateMap(json['sentCampaignAt']),
      impressionCounts: _readIntMap(json['impressionCounts']),
      dismissedCampaignIds: _readStringSet(json['dismissedCampaignIds']),
      sentJourneyIds: _readStringSet(json['sentJourneyIds']),
      history: _readHistory(json['history']),
    );
  }

  static DateTime? _readDate(Object? value) {
    if (value == null) return null;
    return DateTime.tryParse(value.toString())?.toUtc();
  }

  static Map<String, DateTime> _readDateMap(Object? value) {
    if (value is! Map) return const {};
    final result = <String, DateTime>{};
    for (final entry in value.entries) {
      final parsed = _readDate(entry.value);
      if (parsed != null) result[entry.key.toString()] = parsed;
    }
    return result;
  }

  static Map<String, int> _readIntMap(Object? value) {
    if (value is! Map) return const {};
    return value.map(
      (key, count) => MapEntry(
        key.toString(),
        count is int ? count : int.tryParse('$count') ?? 0,
      ),
    );
  }

  static Set<String> _readStringSet(Object? value) {
    if (value is Iterable) {
      return value.map((item) => item.toString()).toSet();
    }
    return const {};
  }

  static List<NotificationHistoryEntry> _readHistory(Object? value) {
    if (value is! Iterable) return const [];
    return value
        .whereType<Map<Object?, Object?>>()
        .map(
            (item) => item.map((key, value) => MapEntry(key.toString(), value)))
        .map(NotificationHistoryEntry.fromJson)
        .toList();
  }
}

class NotificationHistoryEntry {
  const NotificationHistoryEntry({
    required this.id,
    required this.kind,
    required this.title,
    required this.body,
    required this.sentAt,
    this.route,
  });

  final String id;
  final String kind;
  final String title;
  final String body;
  final DateTime sentAt;
  final String? route;

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'kind': kind,
      'title': title,
      'body': body,
      'sentAt': sentAt.toUtc().toIso8601String(),
      'route': route,
    };
  }

  static NotificationHistoryEntry fromJson(Map<String, dynamic> json) {
    return NotificationHistoryEntry(
      id: json['id']?.toString() ?? '',
      kind: json['kind']?.toString() ?? 'notification',
      title: json['title']?.toString() ?? '',
      body: json['body']?.toString() ?? '',
      sentAt: DateTime.tryParse(json['sentAt']?.toString() ?? '')?.toUtc() ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      route: json['route']?.toString(),
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
