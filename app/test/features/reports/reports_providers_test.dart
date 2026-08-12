import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/entities/report_models.dart';
import 'package:money_companion/features/reports/reports_providers.dart';
import 'package:money_companion/domain/finance/money.dart';

void main() {
  test('detectSpendingAnomaly flags a clear daily spike', () {
    final anomaly = detectSpendingAnomaly([
      DailySpend(day: DateTime(2026, 6, 1), total: Money(9000, 'SAR')),
      DailySpend(day: DateTime(2026, 6, 2), total: Money(11000, 'SAR')),
      DailySpend(day: DateTime(2026, 6, 3), total: Money(9500, 'SAR')),
      DailySpend(day: DateTime(2026, 6, 4), total: Money(42000, 'SAR')),
      DailySpend(day: DateTime(2026, 6, 5), total: Money(10000, 'SAR')),
    ]);

    expect(anomaly, isNotNull);
    expect(anomaly!.day, DateTime(2026, 6, 4));
    expect(anomaly.total, Money(42000, 'SAR'));
    expect(anomaly.ratio, greaterThan(4));
  });

  test('detectSpendingAnomaly ignores normal daily variation', () {
    final anomaly = detectSpendingAnomaly([
      DailySpend(day: DateTime(2026, 6, 1), total: Money(9000, 'SAR')),
      DailySpend(day: DateTime(2026, 6, 2), total: Money(11000, 'SAR')),
      DailySpend(day: DateTime(2026, 6, 3), total: Money(9500, 'SAR')),
      DailySpend(day: DateTime(2026, 6, 4), total: Money(13000, 'SAR')),
      DailySpend(day: DateTime(2026, 6, 5), total: Money(10000, 'SAR')),
    ]);

    expect(anomaly, isNull);
  });
}
