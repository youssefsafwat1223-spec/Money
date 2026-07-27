import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/entities/report_models.dart';
import 'package:money_companion/domain/reporting/metrics/comparison_calculator.dart';
import 'package:money_companion/domain/reporting/metrics/report_metrics_calculator.dart';

void main() {
  const calc = ReportMetricsCalculator();
  const cmp = ComparisonCalculator();

  group('computeCashFlow', () {
    test('typical month: net and savings rate', () {
      final m = calc.computeCashFlow(income: 12400, expense: 8730);
      expect(m.net, closeTo(3670, 1e-9));
      expect(m.savingsRate, closeTo(3670 / 12400, 1e-9));
    });

    test('zero income → savings rate is null (undefined), net is -expense', () {
      final m = calc.computeCashFlow(income: 0, expense: 500);
      expect(m.savingsRate, isNull);
      expect(m.net, closeTo(-500, 1e-9));
    });

    test('zero expense → savings rate is 1.0', () {
      final m = calc.computeCashFlow(income: 1000, expense: 0);
      expect(m.savingsRate, closeTo(1.0, 1e-9));
      expect(m.net, closeTo(1000, 1e-9));
    });

    test('overspend → negative net, savings rate clamped to 0', () {
      final m = calc.computeCashFlow(income: 1000, expense: 1500);
      expect(m.net, closeTo(-500, 1e-9));
      expect(m.savingsRate, 0.0);
    });

    test('extremely large amounts keep precision', () {
      final m = calc.computeCashFlow(income: 9999999999.99, expense: 1234567890.12);
      expect(m.net, closeTo(9999999999.99 - 1234567890.12, 1e-2));
    });

    test('per-currency computes one result per currency, never summed', () {
      final rows = calc.computePerCurrency(const [
        CurrencyTotal(currency: 'SAR', expense: 8730, income: 12400),
        CurrencyTotal(currency: 'USD', expense: 200, income: 0),
      ]);
      expect(rows.map((r) => r.currency).toList(), ['SAR', 'USD']);
      expect(rows[0].metrics.net, closeTo(3670, 1e-9));
      expect(rows[1].metrics.savingsRate, isNull); // USD income 0
    });
  });

  group('comparison', () {
    test('expense dropped vs previous', () {
      final d = cmp.delta(8730, 9910);
      expect(d.absolute, closeTo(-1180, 1e-9));
      expect(d.percent, closeTo(-1180 / 9910, 1e-9));
      expect(d.isDecrease, isTrue);
    });

    test('percent is null when previous is zero', () {
      final d = cmp.delta(100, 0);
      expect(d.percent, isNull);
      expect(d.absolute, closeTo(100, 1e-9));
    });

    test('savings-rate delta is in percentage points', () {
      final current = calc.computeCashFlow(income: 12400, expense: 8680); // ~0.30
      final previous = calc.computeCashFlow(income: 12400, expense: 9920); // ~0.20
      final c = cmp.compare(current, previous);
      expect(c.savingsRatePoints, closeTo(0.10, 1e-9));
      expect(c.expense.isDecrease, isTrue);
    });

    test('savings-rate delta is null when a period is undefined', () {
      final current = calc.computeCashFlow(income: 1000, expense: 500);
      final previous = calc.computeCashFlow(income: 0, expense: 500); // undefined
      final c = cmp.compare(current, previous);
      expect(c.savingsRatePoints, isNull);
    });
  });
}
