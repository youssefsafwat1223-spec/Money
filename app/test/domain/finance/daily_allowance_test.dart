import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/entities/report_models.dart';
import 'package:money_companion/domain/finance/daily_allowance.dart';
import 'package:money_companion/domain/finance/money.dart';

Money sar(int minor) => Money(minor, 'SAR');
DailySpend day(DateTime d, int minor) =>
    DailySpend(day: d, total: Money(minor, 'SAR'));

void main() {
  group('normalizeLastSevenDays', () {
    final today = DateTime(2026, 8, 31);

    test('always returns exactly seven ordered slots ending today', () {
      final out =
          normalizeLastSevenDays(rows: const [], today: today, currency: 'SAR');

      expect(out, hasLength(7));
      expect(out.first.day, DateTime(2026, 8, 25));
      expect(out.last.day, DateTime(2026, 8, 31));
      for (var i = 1; i < out.length; i++) {
        expect(out[i].day.isAfter(out[i - 1].day), isTrue,
            reason: 'slots must be ordered oldest → newest');
      }
    });

    test('a day with no spend becomes an explicit zero, not a gap', () {
      final out = normalizeLastSevenDays(
        rows: [day(DateTime(2026, 8, 31), 20000)],
        today: today,
        currency: 'SAR',
      );

      expect(out.last.total, sar(20000));
      // The other six days had no rows at all.
      expect(out.take(6).every((d) => d.total.isZero), isTrue);
    });

    test('values land on their own day — never shifted into a neighbour', () {
      final out = normalizeLastSevenDays(
        rows: [
          // Deliberately unordered, and with a time component, because the SQL
          // aggregate makes no promise about either.
          day(DateTime(2026, 8, 29, 23, 59), 5000),
          day(DateTime(2026, 8, 26, 0, 1), 1000),
        ],
        today: today,
        currency: 'SAR',
      );

      expect(out[1].day, DateTime(2026, 8, 26));
      expect(out[1].total, sar(1000));
      expect(out[4].day, DateTime(2026, 8, 29));
      expect(out[4].total, sar(5000));
      expect(out[2].total.isZero, isTrue);
      expect(out[3].total.isZero, isTrue);
    });

    test('a refund day stays negative — it is a real state, not an error', () {
      final out = normalizeLastSevenDays(
        rows: [day(DateTime(2026, 8, 30), -4500)],
        today: today,
        currency: 'SAR',
      );

      expect(out[5].total, sar(-4500));
      expect(out[5].isRefundDay, isTrue);
    });

    test('rows outside the window are ignored', () {
      final out = normalizeLastSevenDays(
        rows: [day(DateTime(2026, 8, 1), 999999)],
        today: today,
        currency: 'SAR',
      );

      expect(out.every((d) => d.total.isZero), isTrue);
    });
  });

  group('averageDailySpend', () {
    test('is the mean over the whole series, zeros included', () {
      final series = [
        day(DateTime(2026, 8, 30), 10000),
        day(DateTime(2026, 8, 31), 0),
      ];

      expect(averageDailySpend(series, 'SAR'), sar(5000));
    });

    test('an empty series is zero, not a divide-by-zero', () {
      expect(averageDailySpend(const [], 'SAR'), sar(0));
    });
  });

  group('dailyAllowance', () {
    // 31-day month; day 20 leaves 12 days including today.
    final now = DateTime(2026, 8, 20, 13, 0);

    test('splits what is left across the days remaining, today included', () {
      final out = dailyAllowance(
        monthlyLimit: sar(650000),
        spentThisMonth: sar(486075),
        now: now,
      );

      // (650000 − 486075) / 12 = 13660.4 → exact minor-unit arithmetic.
      expect(out, isNotNull);
      expect(out!.currency, 'SAR');
      expect(out.minorUnits, 13660);
    });

    test('is NULL when no monthly budget is set — never a misleading zero', () {
      expect(
        dailyAllowance(
            monthlyLimit: sar(0), spentThisMonth: sar(100), now: now),
        isNull,
      );
    });

    test('is ZERO once the budget is spent — that is the answer', () {
      final out = dailyAllowance(
        monthlyLimit: sar(650000),
        spentThisMonth: sar(650000),
        now: now,
      );

      expect(out, isNotNull);
      expect(out!.isZero, isTrue);
    });

    test('overspending is zero, not a negative allowance', () {
      final out = dailyAllowance(
        monthlyLimit: sar(650000),
        spentThisMonth: sar(700000),
        now: now,
      );

      expect(out!.isZero, isTrue);
    });

    test('the last day of the month divides by one, not zero', () {
      final out = dailyAllowance(
        monthlyLimit: sar(100000),
        spentThisMonth: sar(40000),
        now: DateTime(2026, 8, 31, 9),
      );

      expect(out, sar(60000));
    });

    test('never mixes currencies — returns null instead of summing', () {
      final out = dailyAllowance(
        monthlyLimit: Money(650000, 'SAR'),
        spentThisMonth: Money(100000, 'EGP'),
        now: now,
      );

      expect(out, isNull);
    });

    test('February is 28/29 days, not a hardcoded 30', () {
      // 2026 is not a leap year: 28 days, day 27 leaves 2.
      final out = dailyAllowance(
        monthlyLimit: sar(100000),
        spentThisMonth: sar(60000),
        now: DateTime(2026, 2, 27),
      );

      expect(out, sar(20000));
    });
  });
}
