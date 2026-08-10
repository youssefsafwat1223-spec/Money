import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/entities/bill_entity.dart';
import 'package:money_companion/domain/entities/engagement_entities.dart';
import 'package:money_companion/domain/entities/goal_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
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
      amountMoney: Money.fromLegacyReal(45, 'SAR'),
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

  test(
      'missed day-before slot falls back to a near-term catch-up reminder '
      'instead of dropping the bill (due tomorrow, app opened after 10:00)',
      () {
    final bill = BillEntity(
      id: 'netflix',
      name: 'Netflix',
      amountMoney: Money.fromLegacyReal(45, 'SAR'),
      currency: 'SAR',
      type: BillType.subscription,
      frequency: BillFrequency.monthly,
      nextDueDate: DateTime(2026, 6, 20),
      reminderOn: true,
      isConfirmed: true,
      createdAt: DateTime(2026, 6, 1),
    );

    // Day-before slot was 2026-06-19 10:00 — now is 19th 14:00 (missed it).
    final planned = planner.planBillReminders(
      preferences: const NotificationPreferences(),
      bills: [bill],
      nowRiyadh: DateTime(2026, 6, 19, 14),
    );

    expect(planned, hasLength(1),
        reason: 'the old behavior dropped the bill entirely — no reminder');
    expect(planned.first.scheduledAtRiyadh, DateTime(2026, 6, 19, 14, 30));
    expect(planned.first.title, 'اشتراك Netflix هيتجدد بكرة');
  });

  test('catch-up on the due day itself says "اليوم" and still fires', () {
    final bill = BillEntity(
      id: 'netflix',
      name: 'Netflix',
      amountMoney: Money.fromLegacyReal(45, 'SAR'),
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
      nowRiyadh: DateTime(2026, 6, 20, 12), // due day, midday
    );

    expect(planned, hasLength(1));
    expect(planned.first.title, 'اشتراك Netflix هيتجدد اليوم');
  });

  test('a bill already past its due day is not reminded', () {
    final bill = BillEntity(
      id: 'netflix',
      name: 'Netflix',
      amountMoney: Money.fromLegacyReal(45, 'SAR'),
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
      nowRiyadh: DateTime(2026, 6, 21, 9), // day after due
    );

    expect(planned, isEmpty);
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
          amountMoney: Money.fromLegacyReal(1200, 'SAR'),
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
      amountMoney: Money.fromLegacyReal(45, 'SAR'),
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

  test('falls within [1000000, 1900000), disjoint from bill reminders', () {
    for (var i = 0; i < 200; i++) {
      final id = goalMilestoneNotificationId('goal-range-check-$i');
      expect(id, greaterThanOrEqualTo(1000000));
      expect(id, lessThan(1900000));
      // Must never land in the bill-reminder range [92000, 992000) — the two
      // ranges overlapped before, letting a bill and a goal share an id.
      expect(id, isNot(inInclusiveRange(92000, 991999)));
    }
  });

  // ── notificationEventId / achievementNotificationId (MALI-061n §3) ────────
  group('notificationEventId', () {
    test('is deterministic and depends on type + key, not display text', () {
      expect(
        notificationEventId('achievement', 'streak_7'),
        notificationEventId('achievement', 'streak_7'),
      );
      // Different key → different id; different type → different id.
      expect(
        notificationEventId('achievement', 'streak_7'),
        isNot(notificationEventId('achievement', 'streak_30')),
      );
      expect(
        notificationEventId('achievement', 'streak_7'),
        isNot(notificationEventId('review', 'streak_7')),
      );
    });

    test('lives in its own [2000000, 2900000) range, clear of bills/goals', () {
      for (var i = 0; i < 500; i++) {
        final id = notificationEventId('review', 'txn-$i');
        expect(id, inInclusiveRange(2000000, 2899999));
        expect(id, isNot(inInclusiveRange(92000, 991999))); // bills
        expect(id, isNot(inInclusiveRange(1000000, 1899999))); // goals
      }
    });

    test('achievementNotificationId is a stable function of the key only', () {
      expect(
        achievementNotificationId('big_saver'),
        achievementNotificationId('big_saver'),
      );
      expect(
        achievementNotificationId('big_saver'),
        notificationEventId('achievement', 'big_saver'),
      );
    });
  });

  // ── Reminder reconciliation (MALI-019 §10 / MALI-061n) ────────────────────
  // Reconciliation is re-plan-from-source + capacity-cancel-stale: planScheduled
  // reflects the CURRENT bills+prefs, and schedulePlannedNotifications cancels
  // any managed pending id no longer in the plan (see
  // notification_capacity_planner_test 'cancels managed pending that fell out').
  group('reminder reconciliation', () {
    const planner = NotificationPlanner();
    BillEntity bill({required DateTime due, bool reminderOn = true}) => BillEntity(
          id: 'netflix',
          name: 'Netflix',
          amountMoney: Money.fromLegacyReal(45, 'SAR'),
          currency: 'SAR',
          type: BillType.subscription,
          frequency: BillFrequency.monthly,
          nextDueDate: due,
          reminderOn: reminderOn,
          isConfirmed: true,
          createdAt: DateTime(2026, 6, 1),
        );

    test('editing the due date keeps the SAME id (OS replaces) at a new time',
        () {
      final p1 = planner.planBillReminders(
        preferences: const NotificationPreferences(),
        bills: [bill(due: DateTime(2026, 6, 20))],
        nowRiyadh: DateTime(2026, 6, 12, 9),
      );
      final p2 = planner.planBillReminders(
        preferences: const NotificationPreferences(),
        bills: [bill(due: DateTime(2026, 6, 25))],
        nowRiyadh: DateTime(2026, 6, 12, 9),
      );
      expect(p1.first.id, p2.first.id); // stable → replaces, never duplicates
      expect(p1.first.id, billReminderNotificationId('netflix'));
      expect(p1.first.scheduledAtRiyadh, isNot(p2.first.scheduledAtRiyadh));
    });

    test('disabling a reminder plans nothing (capacity then cancels the stale id)',
        () {
      final planned = planner.planBillReminders(
        preferences: const NotificationPreferences(),
        bills: [bill(due: DateTime(2026, 6, 20), reminderOn: false)],
        nowRiyadh: DateTime(2026, 6, 12, 9),
      );
      expect(planned, isEmpty);
    });

    test('a deleted bill (absent from source) plans nothing', () {
      final planned = planner.planBillReminders(
        preferences: const NotificationPreferences(),
        bills: const [],
        nowRiyadh: DateTime(2026, 6, 12, 9),
      );
      expect(planned, isEmpty);
    });

    test('scheduled times are Riyadh-anchored — device-tz/DST independent', () {
      // planBillReminders is a pure function of the Riyadh wall clock, so a
      // device timezone change cannot shift or duplicate it. Asia/Riyadh has no
      // DST, so there are no gap/overlap transitions to reconcile.
      final planned = planner.planBillReminders(
        preferences: const NotificationPreferences(),
        bills: [bill(due: DateTime(2026, 6, 20))],
        nowRiyadh: DateTime(2026, 6, 12, 9),
      );
      expect(planned.first.scheduledAtRiyadh, DateTime(2026, 6, 19, 10));
    });
  });

  // ── Quiet-hours policy boundaries (MALI-019) ──────────────────────────────
  group('isQuietHour boundaries', () {
    const planner = NotificationPlanner();
    NotificationPreferences qh(int start, int end) => NotificationPreferences(
        quietHoursEnabled: true,
        quietHoursStartHour: start,
        quietHoursEndHour: end);
    DateTime at(int hour) => DateTime(2026, 6, 12, hour);

    test('within-day window: inclusive start, exclusive end', () {
      final p = qh(13, 17);
      expect(planner.isQuietHour(at(12), p), isFalse);
      expect(planner.isQuietHour(at(13), p), isTrue); // start boundary
      expect(planner.isQuietHour(at(16), p), isTrue);
      expect(planner.isQuietHour(at(17), p), isFalse); // end boundary
    });

    test('overnight window crosses midnight', () {
      final p = qh(23, 8);
      expect(planner.isQuietHour(at(23), p), isTrue);
      expect(planner.isQuietHour(at(0), p), isTrue);
      expect(planner.isQuietHour(at(7), p), isTrue);
      expect(planner.isQuietHour(at(8), p), isFalse); // end boundary exclusive
      expect(planner.isQuietHour(at(12), p), isFalse);
    });

    test('disabled quiet hours are never quiet', () {
      expect(
          planner.isQuietHour(at(2), const NotificationPreferences()), isFalse);
    });
  });
}
