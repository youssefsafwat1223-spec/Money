import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/entities/report_models.dart';
import 'package:money_companion/features/reports/reports_providers.dart';

void main() {
  test('detectSpendingAnomaly flags a clear daily spike', () {
    final anomaly = detectSpendingAnomaly([
      DailySpend(day: DateTime(2026, 6, 1), total: 90),
      DailySpend(day: DateTime(2026, 6, 2), total: 110),
      DailySpend(day: DateTime(2026, 6, 3), total: 95),
      DailySpend(day: DateTime(2026, 6, 4), total: 420),
      DailySpend(day: DateTime(2026, 6, 5), total: 100),
    ]);

    expect(anomaly, isNotNull);
    expect(anomaly!.day, DateTime(2026, 6, 4));
    expect(anomaly.total, 420);
    expect(anomaly.ratio, greaterThan(4));
  });

  test('detectSpendingAnomaly ignores normal daily variation', () {
    final anomaly = detectSpendingAnomaly([
      DailySpend(day: DateTime(2026, 6, 1), total: 90),
      DailySpend(day: DateTime(2026, 6, 2), total: 110),
      DailySpend(day: DateTime(2026, 6, 3), total: 95),
      DailySpend(day: DateTime(2026, 6, 4), total: 130),
      DailySpend(day: DateTime(2026, 6, 5), total: 100),
    ]);

    expect(anomaly, isNull);
  });
}
