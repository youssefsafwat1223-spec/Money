// MALI-025 — capacity/rolling-window planner behavior.
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/services/notification_capacity_planner.dart';

void main() {
  final now = DateTime(2026, 8, 5, 12);
  ScheduleCandidate c(int id, int daysAhead, int priority) => ScheduleCandidate(
        id: id,
        due: now.add(Duration(days: daysAhead)),
        priority: priority,
      );

  test('never exceeds capacity minus the immediate reserve', () {
    const planner = NotificationCapacityPlanner(capacity: 10, reservedForImmediate: 2);
    final desired = [for (var i = 0; i < 50; i++) c(i, i + 1, 1)];
    final plan = planner.plan(
      currentManagedPending: const {},
      desired: desired,
      now: now,
    );
    expect(plan.toSchedule.length, 8); // 10 - 2 reserved
  });

  test('prioritizes importance first, then nearest-due', () {
    const planner = NotificationCapacityPlanner(capacity: 4, reservedForImmediate: 1);
    final plan = planner.plan(
      currentManagedPending: const {},
      desired: [
        c(1, 30, 1), // low priority, far
        c(2, 2, 3), // high priority, near  → in
        c(3, 40, 3), // high priority, far  → in
        c(4, 1, 2), // mid priority, near   → in
      ],
      now: now,
    );
    // window budget = 3; picks by priority then due: 2, 3 (both p3, near first),
    // then 4 (p2). The low-priority far #1 is dropped.
    expect(plan.toSchedule.map((c) => c.id).toList(), [2, 3, 4]);
  });

  test('drops past-due candidates and cancels their stale pending', () {
    const planner = NotificationCapacityPlanner(capacity: 10, reservedForImmediate: 0);
    final plan = planner.plan(
      currentManagedPending: const {99},
      desired: [c(99, -1, 5)], // due yesterday
      now: now,
    );
    expect(plan.toSchedule, isEmpty);
    expect(plan.toCancel, {99}); // the stale pending is reclaimed
  });

  test('cancels managed pending that fell out of the window, keeps selected',
      () {
    const planner = NotificationCapacityPlanner(capacity: 3, reservedForImmediate: 0);
    final plan = planner.plan(
      currentManagedPending: const {1, 2, 3, 4, 5},
      desired: [c(1, 1, 1), c(2, 2, 1), c(3, 3, 1)], // 4 and 5 no longer desired
      now: now,
    );
    expect(plan.toSchedule.map((c) => c.id).toSet(), {1, 2, 3});
    expect(plan.toCancel, {4, 5});
  });

  test('a tiny/over-reserved capacity schedules nothing (fails safe)', () {
    const planner = NotificationCapacityPlanner(capacity: 2, reservedForImmediate: 5);
    final plan = planner.plan(
      currentManagedPending: const {},
      desired: [c(1, 1, 9)],
      now: now,
    );
    expect(plan.toSchedule, isEmpty);
  });
}
