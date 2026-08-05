// MALI-019 §10 — the sign-out cancellation set. cancelScheduledReminders()
// cancels exactly these ids (its OS-level effect needs the plugin/device, but
// the id-selection logic is directly testable and must never include foreign /
// immediate notifications).
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/services/notification_planner.dart';
import 'package:money_companion/features/capture/services/local_notification_service.dart';

void main() {
  test('managed reminder ids cover bills, weekly report and streak', () {
    // Bill/subscription reminders (deterministic ids in [92000, 992000)).
    expect(
      LocalNotificationService.isManagedReminderId(
          billReminderNotificationId('netflix')),
      isTrue,
    );
    // Weekly report + streak (fixed ids).
    expect(LocalNotificationService.isManagedReminderId(91001), isTrue);
    expect(LocalNotificationService.isManagedReminderId(88008), isTrue);
  });

  test('never cancels immediate/foreign notifications', () {
    // Goal-milestone range [1000000, 1900000) and the review/achievement event
    // range [2000000, 2900000) are immediate, not scheduled reminders.
    expect(
      LocalNotificationService.isManagedReminderId(
          goalMilestoneNotificationId('emergency')),
      isFalse,
    );
    expect(
      LocalNotificationService.isManagedReminderId(
          notificationEventId('review', 'txn-1')),
      isFalse,
    );
    expect(LocalNotificationService.isManagedReminderId(0), isFalse);
  });
}
