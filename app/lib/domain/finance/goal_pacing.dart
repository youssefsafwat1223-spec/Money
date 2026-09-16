import 'money.dart';

/// UX-025 — what a savings goal needs in order to be a plan rather than a
/// number.
///
/// Both seeded goals carry a `deadline` that the app never rendered anywhere.
/// It reaches the exported PDF report and it orders the Home preview — so the
/// data was trusted enough to sort by and to print, and still never shown to
/// the user on the screen where they manage the goal.
///
/// The figure that actually makes a goal actionable — how much per month is
/// required to hit the target on time — is derivable from data already present
/// and was never displayed either. The QA put it plainly: *"A savings goal
/// without a date is a number, not a plan."*
///
/// The internal inconsistency was the tell: Subscriptions renders «بعد 3 يوم»
/// and the installment card «القسط القادم: بعد 7 يوم». Time-to-target was
/// surfaced for obligations and withheld from goals.
class GoalPacing {
  const GoalPacing({
    required this.remaining,
    required this.daysRemaining,
    required this.requiredPerMonth,
    required this.isOverdue,
  });

  /// Target minus saved, floored at zero.
  final Money remaining;

  /// Whole days from today to the deadline. Negative once the date has passed.
  final int daysRemaining;

  /// Contribution per month needed to reach the target by the deadline.
  ///
  /// Null when there is no deadline, when the goal is already met, or when the
  /// deadline has passed — in each case a "required rate" would be a fiction
  /// rather than a plan.
  final Money? requiredPerMonth;

  final bool isOverdue;
}

/// Computes pacing for a goal. Pure arithmetic in exact minor units.
///
/// [now] is injected rather than read from the clock so the result is
/// deterministic and testable — a pacing figure that changes with wall-clock
/// time inside a test is untestable by construction.
GoalPacing goalPacing({
  required Money target,
  required Money saved,
  required DateTime? deadline,
  required DateTime now,
}) {
  final remainingMinor = target.minorUnits - saved.minorUnits;
  final remaining =
      Money(remainingMinor > 0 ? remainingMinor : 0, target.currency);

  if (deadline == null) {
    return GoalPacing(
      remaining: remaining,
      daysRemaining: 0,
      requiredPerMonth: null,
      isOverdue: false,
    );
  }

  // Date-only difference: a deadline is a day, not an instant, so a goal due
  // today is not "overdue by a few hours".
  final today = DateTime(now.year, now.month, now.day);
  final due = DateTime(deadline.year, deadline.month, deadline.day);
  final days = due.difference(today).inDays;

  if (remaining.isZero || days < 0) {
    return GoalPacing(
      remaining: remaining,
      daysRemaining: days,
      requiredPerMonth: null,
      isOverdue: days < 0 && !remaining.isZero,
    );
  }

  // Months remaining, at least one: with 20 days left the honest statement is
  // "this month", not "0.66 of a month".
  final months = (days / 30).ceil().clamp(1, 1 << 30);

  // Rounded UP. Understating the required contribution would let a goal read as
  // on-track while it silently misses its date — the opposite of the point.
  final perMonthMinor = (remaining.minorUnits + months - 1) ~/ months;

  return GoalPacing(
    remaining: remaining,
    daysRemaining: days,
    requiredPerMonth: Money(perMonthMinor, target.currency),
    isOverdue: false,
  );
}

/// Where a goal lands at the user's OWN pace, as opposed to the pace its
/// deadline demands.
///
/// [GoalPacing.requiredPerMonth] answers "what should I put in each month".
/// This answers "what happens if I keep doing exactly what I am doing" — and
/// the gap between the two is the only sentence a user can act on
/// («هتوصل في مارس — متأخر شهرين»).
class GoalProjection {
  const GoalProjection({
    required this.actualPerMonth,
    required this.monthsToTarget,
    required this.arrivesOn,
    required this.monthsLate,
  });

  /// Observed contribution rate: saved ÷ months since the goal was created.
  final Money actualPerMonth;

  /// Whole months from now until the target is reached at [actualPerMonth].
  /// Null when the rate is zero — an unbounded date is not a projection.
  final int? monthsToTarget;

  /// Projected arrival date; null whenever [monthsToTarget] is null.
  final DateTime? arrivesOn;

  /// Months past the deadline the projection lands on. Null when there is no
  /// deadline or no projection; zero or negative means on time or early.
  final int? monthsLate;

  bool get isLate => (monthsLate ?? 0) > 0;
}

/// Projects a goal forward from the rate it has ACTUALLY been funded at.
///
/// Deliberately conservative:
///   * a goal younger than a month is measured over one month, never over a
///     fraction, so a three-day-old goal cannot report a fantastical rate;
///   * a zero rate yields a null date rather than "never" — the UI should say
///     "no contributions yet" instead of printing an infinity;
///   * an already-met goal projects nothing.
///
/// [now] is injected for the same reason as in [goalPacing]: a figure that
/// changes with wall-clock time inside a test is untestable by construction.
GoalProjection goalProjection({
  required Money target,
  required Money saved,
  required DateTime createdAt,
  required DateTime? deadline,
  required DateTime now,
}) {
  final elapsedDays = now.difference(createdAt).inDays;
  final elapsedMonths = (elapsedDays / 30).floor().clamp(1, 1 << 30);
  final ratePerMonth = Money(saved.minorUnits ~/ elapsedMonths, target.currency);

  final remainingMinor = target.minorUnits - saved.minorUnits;
  if (remainingMinor <= 0 || ratePerMonth.minorUnits <= 0) {
    return GoalProjection(
      actualPerMonth: ratePerMonth,
      monthsToTarget: null,
      arrivesOn: null,
      monthsLate: null,
    );
  }

  // Rounded UP: a partial month still has to be lived through.
  final months =
      (remainingMinor + ratePerMonth.minorUnits - 1) ~/ ratePerMonth.minorUnits;
  final arrival = DateTime(now.year, now.month + months, now.day);

  return GoalProjection(
    actualPerMonth: ratePerMonth,
    monthsToTarget: months,
    arrivesOn: arrival,
    monthsLate: deadline == null
        ? null
        : (arrival.year - deadline.year) * 12 +
            (arrival.month - deadline.month),
  );
}
