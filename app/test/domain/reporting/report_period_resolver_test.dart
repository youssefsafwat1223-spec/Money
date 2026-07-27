import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/reporting/date_range.dart';
import 'package:money_companion/domain/reporting/metrics/report_period_resolver.dart';
import 'package:money_companion/domain/reporting/report_request.dart';

void main() {
  const resolver = ReportPeriodResolver();

  group('MonthlyPeriod', () {
    test('resolves to the full calendar month containing now', () {
      final r = resolver.resolve(
        const MonthlyPeriod(),
        now: DateTime(2026, 7, 15, 13, 30),
      );
      expect(r.range, DateRange(DateTime(2026, 7), DateTime(2026, 8)));
      expect(r.range.length, const Duration(days: 31));
    });

    test('previous window is the full previous month (unequal length ok)', () {
      final r = resolver.resolve(
        const MonthlyPeriod(),
        now: DateTime(2026, 7, 15),
      );
      expect(r.previousRange, DateRange(DateTime(2026, 6), DateTime(2026, 7)));
      expect(r.previousRange.length, const Duration(days: 30));
    });

    test('January rolls the previous window back into December', () {
      final r = resolver.resolve(
        const MonthlyPeriod(),
        now: DateTime(2026, 1, 10),
      );
      expect(r.range, DateRange(DateTime(2026, 1), DateTime(2026, 2)));
      expect(
        r.previousRange,
        DateRange(DateTime(2025, 12), DateTime(2026, 1)),
      );
    });

    test('February in a leap year spans 29 days', () {
      final r = resolver.resolve(
        const MonthlyPeriod(),
        now: DateTime(2024, 2, 10),
      );
      expect(r.range, DateRange(DateTime(2024, 2), DateTime(2024, 3)));
      expect(r.range.length, const Duration(days: 29));
    });
  });

  group('YearlyPeriod', () {
    test('resolves to the calendar year and previous year', () {
      final r = resolver.resolve(
        const YearlyPeriod(),
        now: DateTime(2026, 7, 15),
      );
      expect(r.range, DateRange(DateTime(2026), DateTime(2027)));
      expect(r.previousRange, DateRange(DateTime(2025), DateTime(2026)));
    });

    test('leap year length is 366 days', () {
      final r = resolver.resolve(
        const YearlyPeriod(),
        now: DateTime(2024, 6, 1),
      );
      expect(r.range.length, const Duration(days: 366));
    });
  });

  group('WeeklyPeriod', () {
    test('starts on Saturday and spans exactly 7 days containing now', () {
      final now = DateTime(2026, 7, 15, 9); // a Wednesday
      final r = resolver.resolve(const WeeklyPeriod(), now: now);
      expect(r.range.from.weekday, DateTime.saturday);
      expect(r.range.length, const Duration(days: 7));
      expect(r.range.contains(now), isTrue);
    });

    test('previous window is the 7 days immediately before', () {
      final r = resolver.resolve(
        const WeeklyPeriod(),
        now: DateTime(2026, 7, 15),
      );
      expect(r.previousRange.length, const Duration(days: 7));
      expect(r.previousRange.to, r.range.from);
      expect(r.previousRange.from, r.range.from.subtract(const Duration(days: 7)));
    });
  });

  group('CustomPeriod', () {
    test('passes bounds through and previous is an equal-length prior window', () {
      final from = DateTime(2026, 3, 10);
      final to = DateTime(2026, 3, 20);
      final r = resolver.resolve(CustomPeriod(from: from, to: to));
      expect(r.range, DateRange(from, to));
      expect(r.range.length, const Duration(days: 10));
      // 10 days before `from`, ending exactly at `from`. Crosses into February.
      expect(r.previousRange, DateRange(DateTime(2026, 2, 28), from));
      expect(r.previousRange.length, const Duration(days: 10));
    });
  });

  group('ReportRequest', () {
    test('accountId reflects the scope', () {
      const all = ReportRequest(period: MonthlyPeriod());
      expect(all.accountId, isNull);
      const single = ReportRequest(
        period: MonthlyPeriod(),
        scope: SingleAccountScope('acc-1'),
      );
      expect(single.accountId, 'acc-1');
    });

    test('isRtl follows the language code', () {
      expect(const ReportRequest(period: MonthlyPeriod()).isRtl, isTrue); // ar default
      expect(
        const ReportRequest(period: MonthlyPeriod(), languageCode: 'en').isRtl,
        isFalse,
      );
    });
  });
}
