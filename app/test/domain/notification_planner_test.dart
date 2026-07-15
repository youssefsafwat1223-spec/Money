import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/entities/bill_entity.dart';
import 'package:money_companion/domain/entities/engagement_entities.dart';
import 'package:money_companion/domain/entities/goal_entity.dart';
import 'package:money_companion/domain/services/notification_planner.dart';

void main() {
  const planner = NotificationPlanner();

  test('weekly report is scheduled on Saturday at 09:00 Riyadh', () {
    final planned = planner.planWeeklyReport(
      preferences: const NotificationPreferences(),
      nowRiyadh: DateTime(2026, 6, 10, 12),
    );

    expect(planned, isNotNull);
    expect(planned!.title, 'تقريرك الأسبوعي جاهز');
    expect(planned.scheduledAtRiyadh, DateTime(2026, 6, 13, 9));
    expect(planned.payload, 'reports');
  });

  test('bill reminders are scheduled one day before due date at 10:00', () {
    final bill = BillEntity(
      id: 'netflix',
      name: 'Netflix',
      amount: 45,
      currency: 'SAR',
      type: BillType.subscription,
      frequency: BillFrequency.monthly,
      nextDueDate: DateTime(2026, 6, 20),
      reminderOn: true,
      isConfirmed: true,
      createdAt: DateTime(2026, 6, 1),
    );

    final planned = planner.planBillReminders(
      preferences: const NotificationPreferences(),
      bills: [bill],
      nowRiyadh: DateTime(2026, 6, 12, 9),
    );

    expect(planned, hasLength(1));
    expect(planned.first.title, 'اشتراك Netflix هيتجدد بكرة');
    expect(planned.first.body, '45 SAR');
    expect(planned.first.scheduledAtRiyadh, DateTime(2026, 6, 19, 10));
  });

  test('quiet hours move scheduled notifications to allowed morning time', () {
    const preferences = NotificationPreferences(
      quietHoursEnabled: true,
      quietHoursStartHour: 23,
      quietHoursEndHour: 8,
    );
    final next = planner.nextAllowedRiyadh(
      DateTime(2026, 6, 12, 23, 30),
      preferences,
    );

    expect(next, DateTime(2026, 6, 13, 8));
  });

  test('quiet hours are off by default', () {
    final next = planner.nextAllowedRiyadh(
      DateTime(2026, 6, 12, 23, 30),
      const NotificationPreferences(),
    );

    expect(next, DateTime(2026, 6, 12, 23, 30));
  });

  test('goal milestone crossing 48 to 52 fires 50 once', () {
    final goal = GoalEntity(
      id: 'emergency',
      name: 'الطوارئ',
      targetAmount: 1000,
      savedAmount: 520,
      vaultSkin: 'amber',
      status: 'active',
      createdAt: DateTime(2026, 6, 1),
    );
    final first = planner.planGoalMilestone(
      preferences: const NotificationPreferences(),
      goal: goal,
      beforeProgress: 0.48,
      afterProgress: 0.52,
    );
    final second = planner.planGoalMilestone(
      preferences: const NotificationPreferences(
        notifiedGoalMilestones: {'emergency': 50},
      ),
      goal: goal,
      beforeProgress: 0.48,
      afterProgress: 0.52,
    );

    expect(first, isNotNull);
    expect(first!.milestone, 50);
    expect(first.title, 'خزنة الطوارئ وصلت 50%!');
    expect(second, isNull);
  });

  test('disabled preferences skip weekly and subscription planning', () {
    final planned = planner.planScheduled(
      preferences: const NotificationPreferences(
        weeklyReport: false,
        subscriptionReminder: false,
      ),
      bills: [
        BillEntity(
          id: 'installment',
          name: 'قسط سيارة',
          amount: 1200,
          currency: 'SAR',
          type: BillType.installment,
          frequency: BillFrequency.monthly,
          nextDueDate: DateTime(2026, 6, 20),
          reminderOn: true,
          isConfirmed: true,
          createdAt: DateTime(2026, 6, 1),
        ),
      ],
      nowRiyadh: DateTime(2026, 6, 12, 9),
    );

    expect(planned, isEmpty);
  });

  // ── billReminderNotificationId (collision-resistant scheme) ──────────────
  //
  // Previously derived from bill.id.hashCode — Dart's hashCode isn't
  // guaranteed to distribute uniformly and isn't stable across Dart versions
  // (the same reasoning that already rules it out for feature-flag
  // bucketing). Now derived from SHA-256, matching that convention.

  test('is deterministic for the same bill id', () {
    expect(
      billReminderNotificationId('netflix-sub-1'),
      billReminderNotificationId('netflix-sub-1'),
    );
  });

  test('differs for different bill ids in practice', () {
    final ids = {
      for (var i = 0; i < 500; i++) billReminderNotificationId('bill-$i'),
    };
    // 500 distinct inputs into a ~900,000-slot range: any collision at all
    // would be a red flag for a properly-distributed hash, but the
    // probability of hitting zero collisions by chance with a good hash is
    // still ~87% at this sample size — assert no collisions rather than a
    // weaker "mostly distinct" threshold.
    expect(ids, hasLength(500));
  });

  test('always falls within the reserved [92000, 992000) range', () {
    for (var i = 0; i < 200; i++) {
      final id = billReminderNotificationId('bill-range-check-$i');
      expect(id, greaterThanOrEqualTo(92000));
      expect(id, lessThan(992000));
    }
  });

  test('planBillReminders uses the collision-resistant id scheme', () {
    final bill = BillEntity(
      id: 'netflix',
      name: 'Netflix',
      amount: 45,
      currency: 'SAR',
      type: BillType.subscription,
      frequency: BillFrequency.monthly,
      nextDueDate: DateTime(2026, 6, 20),
      reminderOn: true,
      isConfirmed: true,
      createdAt: DateTime(2026, 6, 1),
    );

    final planned = planner.planBillReminders(
      preferences: const NotificationPreferences(),
      bills: [bill],
      nowRiyadh: DateTime(2026, 6, 12, 9),
    );

    expect(planned.first.id, billReminderNotificationId('netflix'));
  });

  // ── goalMilestoneNotificationId (same collision-resistant scheme) ────────
  //
  // Previously derived from goal.hashCode at the call site
  // (local_notification_service.dart's showGoalMilestoneNotification) — the
  // exact same vulnerable pattern as the bill-reminder scheme, despite a
  // prior audit's claim that goal milestones had "already been fixed". Now
  // shares the same SHA-256-based helper as bills, with its own base so the
  // previously-reserved [93000, 993000) range is preserved.

  test('is deterministic for the same goal id', () {
    expect(
      goalMilestoneNotificationId('emergency-fund'),
      goalMilestoneNotificationId('emergency-fund'),
    );
  });

  test('differs for different goal ids in practice', () {
    final ids = {
      for (var i = 0; i < 500; i++) goalMilestoneNotificationId('goal-$i'),
    };
    expect(ids, hasLength(500));
  });

  test('always falls within the previously-reserved [93000, 993000) range',
      () {
    for (var i = 0; i < 200; i++) {
      final id = goalMilestoneNotificationId('goal-range-check-$i');
      expect(id, greaterThanOrEqualTo(93000));
      expect(id, lessThan(993000));
    }
  });

}
