// MALI-025 — iOS has a hard limit (~64) on pending local-notification requests;
// past it, new schedules are silently dropped. This pure planner decides which
// of the desired reminders actually get scheduled: it keeps an internal cap
// BELOW the platform max, reserves headroom for immediate/high-priority alerts,
// prioritizes by importance then nearest-due, and rolls the window forward
// (distant recurrences are scheduled later, on the next replenish) rather than
// burning the whole budget on far-future dates.
//
// Pure and platform-free so the capacity policy is unit-tested without a real
// notification center; [LocalNotificationService] supplies the live pending set
// and applies the resulting cancel/schedule plan.
library;

/// One reminder the app would like scheduled.
class ScheduleCandidate {
  const ScheduleCandidate({
    required this.id,
    required this.due,
    required this.priority,
  });

  final int id;

  /// When it should fire. Past-due candidates (before `now`) are not scheduled.
  final DateTime due;

  /// Higher = more important. Ties break by nearest [due].
  final int priority;
}

/// The decision: which candidates to schedule, and which currently-pending
/// managed ids to cancel (they were dropped from the window).
class CapacityPlan {
  const CapacityPlan({required this.toSchedule, required this.toCancel});

  final List<ScheduleCandidate> toSchedule;
  final Set<int> toCancel;
}

class NotificationCapacityPlanner {
  const NotificationCapacityPlanner({
    this.capacity = 60,
    this.reservedForImmediate = 8,
  })  : assert(capacity > 0),
        assert(reservedForImmediate >= 0);

  /// Internal cap, deliberately below iOS's ~64 platform maximum.
  final int capacity;

  /// Headroom left unused by scheduled reminders so an immediate/high-priority
  /// alert (a capture review, a security event) always has room.
  final int reservedForImmediate;

  int get _windowBudget {
    final budget = capacity - reservedForImmediate;
    return budget < 0 ? 0 : budget;
  }

  /// Plans the managed reminder window.
  ///
  /// [currentManagedPending] is the set of pending ids the app owns (so we never
  /// cancel a foreign/immediate notification). [desired] is every reminder we
  /// would schedule if capacity were unlimited. [now] filters out past-due.
  CapacityPlan plan({
    required Set<int> currentManagedPending,
    required List<ScheduleCandidate> desired,
    required DateTime now,
  }) {
    final future = desired.where((c) => !c.due.isBefore(now)).toList()
      ..sort((a, b) {
        final byPriority = b.priority.compareTo(a.priority);
        if (byPriority != 0) return byPriority;
        return a.due.compareTo(b.due); // nearest-due first within a priority
      });

    final selected = <ScheduleCandidate>[];
    final seenIds = <int>{};
    for (final candidate in future) {
      if (selected.length >= _windowBudget) break;
      if (seenIds.add(candidate.id)) selected.add(candidate);
    }

    final selectedIds = selected.map((c) => c.id).toSet();
    final toCancel = currentManagedPending.difference(selectedIds);
    return CapacityPlan(toSchedule: selected, toCancel: toCancel);
  }
}
