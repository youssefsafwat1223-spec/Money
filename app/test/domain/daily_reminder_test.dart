import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/entities/engagement_entities.dart';
import 'package:money_companion/domain/services/notification_planner.dart';
import 'package:money_companion/features/capture/services/local_notification_service.dart';

/// V1 daily reminder at 22:00 device-local (charter:
/// REQUIRED_PRODUCT_CHANGE_4). It replaces the retired streak reminder, which
/// was the app's only daily nudge and fired at 20:00.
void main() {
  const planner = NotificationPlanner();
  const prefs = NotificationPreferences();

  test('fires at 22:00, not at the retired 20:00', () {
    final plan = planner.planDailyReminder(
      preferences: prefs,
      nowRiyadh: DateTime(2026, 9, 15, 9),
    )!;
    expect(dailyReminderHour, 22);
    expect(plan.scheduledAtRiyadh, DateTime(2026, 9, 15, 22));
    expect(plan.scheduledAtRiyadh.hour, isNot(20));
  });

  test('never schedules into the past — after 22:00 it rolls to tomorrow', () {
    // A reminder planned into the past either fires instantly or is dropped;
    // both are wrong, and the second is invisible.
    final plan = planner.planDailyReminder(
      preferences: prefs,
      nowRiyadh: DateTime(2026, 9, 15, 22, 30),
    )!;
    expect(plan.scheduledAtRiyadh, DateTime(2026, 9, 16, 22));
  });

  test('exactly 22:00 counts as passed, so it does not double-fire', () {
    final plan = planner.planDailyReminder(
      preferences: prefs,
      nowRiyadh: DateTime(2026, 9, 15, 22),
    )!;
    expect(plan.scheduledAtRiyadh, DateTime(2026, 9, 16, 22));
  });

  test('the setting genuinely disables it', () {
    expect(
      planner.planDailyReminder(
        preferences: prefs.copyWith(dailyReminder: false),
        nowRiyadh: DateTime(2026, 9, 15, 9),
      ),
      isNull,
    );
  });

  test('quiet hours push it out rather than firing inside them', () {
    // 22:00 sits inside a 21:00–08:00 quiet window, so the reminder must move
    // to the end of the window instead of being silently delivered anyway.
    final quiet = prefs.copyWith(
      quietHoursEnabled: true,
      quietHoursStartHour: 21,
      quietHoursEndHour: 8,
    );
    final plan = planner.planDailyReminder(
      preferences: quiet,
      nowRiyadh: DateTime(2026, 9, 15, 9),
    )!;
    expect(planner.isQuietHour(plan.scheduledAtRiyadh, quiet), isFalse);
    expect(plan.scheduledAtRiyadh.hour, 8);
  });

  test('re-planning is idempotent: one fixed id, never a second request', () {
    // The id is what makes a reschedule overwrite rather than stack. If this
    // ever became derived from the time or the copy, every re-plan would leave
    // an extra pending notification behind.
    final a = planner.planDailyReminder(
        preferences: prefs, nowRiyadh: DateTime(2026, 9, 15, 9))!;
    final b = planner.planDailyReminder(
        preferences: prefs, nowRiyadh: DateTime(2026, 9, 15, 11))!;
    expect(a.id, b.id);
    expect(a.id, dailyReminderNotificationId);
    expect(a.id, isNot(LocalNotificationService.retiredStreakReminderId));
  });

  test('sign-out cancels it — it is inside the managed set', () {
    expect(
      LocalNotificationService.isManagedReminderId(dailyReminderNotificationId),
      isTrue,
      reason: 'otherwise the previous user keeps receiving it after sign-out',
    );
  });

  test('it is planned as part of the normal scheduled sweep', () {
    final planned = planner.planScheduled(
      preferences: prefs,
      bills: const [],
      nowRiyadh: DateTime(2026, 9, 15, 9),
    );
    expect(
      planned.where((p) => p.kind == PlannedNotificationKind.dailyReminder),
      hasLength(1),
    );
  });

  test('the preference round-trips and defaults on', () {
    expect(const NotificationPreferences().dailyReminder, isTrue);
    final json = prefs.copyWith(dailyReminder: false).toJson();
    expect(NotificationPreferences.fromJson(json).dailyReminder, isFalse);
    // An install that predates the field must not silently lose the reminder.
    expect(NotificationPreferences.fromJson(const {}).dailyReminder, isTrue);
  });
}
