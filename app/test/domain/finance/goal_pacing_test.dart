import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/finance/goal_pacing.dart';
import 'package:money_companion/domain/finance/money.dart';

/// UX-025 — the numbers that turn a goal into a plan.
void main() {
  final now = DateTime(2026, 8, 29);

  GoalPacing pace(int targetMinor, int savedMinor, DateTime? deadline) =>
      goalPacing(
        target: Money(targetMinor, 'SAR'),
        saved: Money(savedMinor, 'SAR'),
        deadline: deadline,
        now: now,
      );

  group("the QA's own two goals", () {
    test('صندوق الطوارئ — 31,500 remaining to 2027-06-25', () {
      final p = pace(5000000, 1850000, DateTime(2027, 6, 25));
      expect(p.remaining, Money(3150000, 'SAR'));
      expect(p.daysRemaining, 300);
      // 300 days → 10 months → 3,150.00/month, matching the QA's ≈3,150.
      expect(p.requiredPerMonth, Money(315000, 'SAR'));
    });

    test('رحلة إسطنبول — 7,700 remaining to 2027-01-25', () {
      final p = pace(1200000, 430000, DateTime(2027, 1, 25));
      expect(p.remaining, Money(770000, 'SAR'));
      expect(p.daysRemaining, 149);
      // 149 days → 5 months → 1,540.00/month, matching the QA's ≈1,540.
      expect(p.requiredPerMonth, Money(154000, 'SAR'));
    });
  });

  group('the rate is honest rather than flattering', () {
    test('rounds UP so a goal cannot read as on-track while missing its date',
        () {
      // 100.00 over 3 months is 33.333…; 33.33 × 3 = 99.99, which misses.
      final p = pace(10000, 0, now.add(const Duration(days: 90)));
      expect(p.requiredPerMonth, Money(3334, 'SAR'));
      expect(p.requiredPerMonth!.minorUnits * 3,
          greaterThanOrEqualTo(p.remaining.minorUnits));
    });

    test('a partial month counts as a whole month', () {
      // 20 days left is "this month", not 0.66 of one.
      final p = pace(30000, 0, now.add(const Duration(days: 20)));
      expect(p.requiredPerMonth, Money(30000, 'SAR'));
    });
  });

  group('cases where a required rate would be a fiction', () {
    test('no deadline → no rate', () {
      expect(pace(10000, 0, null).requiredPerMonth, isNull);
    });

    test('already reached → no rate, and no negative remaining', () {
      final p = pace(10000, 12000, now.add(const Duration(days: 30)));
      expect(p.remaining, Money.zero('SAR'));
      expect(p.requiredPerMonth, isNull);
      expect(p.isOverdue, isFalse);
    });

    test('deadline passed with money still owed → overdue, no rate', () {
      final p = pace(10000, 4000, now.subtract(const Duration(days: 5)));
      expect(p.isOverdue, isTrue);
      expect(p.requiredPerMonth, isNull);
    });

    test('due today is not overdue', () {
      // A deadline is a day, not an instant.
      final p = pace(10000, 0, now);
      expect(p.isOverdue, isFalse);
      expect(p.daysRemaining, 0);
    });
  });

  group('exactness', () {
    test('a 3-decimal currency keeps its scale', () {
      final p = goalPacing(
        target: Money(120000, 'KWD'), // 120.000
        saved: Money(20000, 'KWD'), //  20.000
        deadline: now.add(const Duration(days: 60)),
        now: now,
      );
      expect(p.remaining, Money(100000, 'KWD'));
      expect(p.requiredPerMonth, Money(50000, 'KWD')); // 50.000/month
    });
  });
}
