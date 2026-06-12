import '../entities/bill_entity.dart';
import '../entities/engagement_entities.dart';
import '../entities/goal_entity.dart';

enum PlannedNotificationKind {
  weeklyReport,
  subscriptionReminder,
}

class PlannedLocalNotification {
  const PlannedLocalNotification({
    required this.id,
    required this.kind,
    required this.title,
    required this.body,
    required this.scheduledAtRiyadh,
    this.payload,
  });

  final int id;
  final PlannedNotificationKind kind;
  final String title;
  final String body;
  final DateTime scheduledAtRiyadh;
  final String? payload;
}

class GoalMilestoneNotification {
  const GoalMilestoneNotification({
    required this.goalId,
    required this.goalName,
    required this.milestone,
    required this.title,
    required this.body,
  });

  final String goalId;
  final String goalName;
  final int milestone;
  final String title;
  final String body;
}

class NotificationPlanner {
  const NotificationPlanner();

  List<PlannedLocalNotification> planScheduled({
    required NotificationPreferences preferences,
    required List<BillEntity> bills,
    required DateTime nowRiyadh,
  }) {
    final planned = <PlannedLocalNotification>[];
    final weekly = planWeeklyReport(
      preferences: preferences,
      nowRiyadh: nowRiyadh,
    );
    if (weekly != null) planned.add(weekly);
    planned.addAll(
      planBillReminders(
        preferences: preferences,
        bills: bills,
        nowRiyadh: nowRiyadh,
      ),
    );
    return planned;
  }

  PlannedLocalNotification? planWeeklyReport({
    required NotificationPreferences preferences,
    required DateTime nowRiyadh,
  }) {
    if (!preferences.weeklyReport) return null;
    var scheduled = DateTime(
      nowRiyadh.year,
      nowRiyadh.month,
      nowRiyadh.day,
      9,
    );
    final daysUntilSaturday = (DateTime.saturday - nowRiyadh.weekday) % 7;
    scheduled = scheduled.add(Duration(days: daysUntilSaturday));
    if (!scheduled.isAfter(nowRiyadh)) {
      scheduled = scheduled.add(const Duration(days: 7));
    }
    scheduled = nextAllowedRiyadh(scheduled, preferences);
    return PlannedLocalNotification(
      id: 91001,
      kind: PlannedNotificationKind.weeklyReport,
      title: 'تقريرك الأسبوعي جاهز',
      body: 'شوف وين راحت فلوسك الأسبوع اللي فات',
      scheduledAtRiyadh: scheduled,
      payload: 'reports',
    );
  }

  List<PlannedLocalNotification> planBillReminders({
    required NotificationPreferences preferences,
    required List<BillEntity> bills,
    required DateTime nowRiyadh,
  }) {
    if (!preferences.subscriptionReminder) return const [];
    final planned = <PlannedLocalNotification>[];
    for (final bill in bills) {
      if (!bill.reminderOn) continue;
      var scheduled = DateTime(
        bill.nextDueDate.year,
        bill.nextDueDate.month,
        bill.nextDueDate.day,
        10,
      ).subtract(const Duration(days: 1));
      if (!scheduled.isAfter(nowRiyadh)) continue;
      scheduled = nextAllowedRiyadh(scheduled, preferences);
      final label = bill.type == BillType.installment ? 'قسط' : 'اشتراك';
      planned.add(
        PlannedLocalNotification(
          id: 92000 + bill.id.hashCode.abs().remainder(900000),
          kind: PlannedNotificationKind.subscriptionReminder,
          title: '$label ${bill.name} هيتجدد بكرة',
          body: '${bill.amount.toStringAsFixed(0)} ${bill.currency}',
          scheduledAtRiyadh: scheduled,
          payload: 'bills',
        ),
      );
    }
    return planned;
  }

  GoalMilestoneNotification? planGoalMilestone({
    required NotificationPreferences preferences,
    required GoalEntity goal,
    required double beforeProgress,
    required double afterProgress,
  }) {
    if (!preferences.goalMilestone) return null;
    final milestone = crossedGoalMilestone(
      beforeProgress: beforeProgress,
      afterProgress: afterProgress,
      lastNotifiedMilestone: preferences.notifiedGoalMilestones[goal.id] ?? 0,
    );
    if (milestone == null) return null;
    return GoalMilestoneNotification(
      goalId: goal.id,
      goalName: goal.name,
      milestone: milestone,
      title: 'خزنة ${goal.name} وصلت $milestone%!',
      body: 'أداء ممتاز، أنت في المسار الصحيح.',
    );
  }

  int? crossedGoalMilestone({
    required double beforeProgress,
    required double afterProgress,
    required int lastNotifiedMilestone,
  }) {
    const milestones = [25, 50, 75, 100];
    for (final milestone in milestones) {
      final checkpoint = milestone / 100;
      if (milestone > lastNotifiedMilestone &&
          beforeProgress < checkpoint &&
          afterProgress >= checkpoint) {
        return milestone;
      }
    }
    return null;
  }

  DateTime nextAllowedRiyadh(
    DateTime dateTime,
    NotificationPreferences preferences,
  ) {
    if (!isQuietHour(dateTime, preferences)) return dateTime;
    final sameDay = DateTime(
      dateTime.year,
      dateTime.month,
      dateTime.day,
      preferences.quietHoursEndHour,
    );
    if (dateTime.hour < preferences.quietHoursEndHour) {
      return sameDay;
    }
    return sameDay.add(const Duration(days: 1));
  }

  bool isQuietHour(
    DateTime dateTime,
    NotificationPreferences preferences,
  ) {
    final hour = dateTime.hour;
    if (preferences.quietHoursStartHour > preferences.quietHoursEndHour) {
      return hour >= preferences.quietHoursStartHour ||
          hour < preferences.quietHoursEndHour;
    }
    return hour >= preferences.quietHoursStartHour &&
        hour < preferences.quietHoursEndHour;
  }
}
