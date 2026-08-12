import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/entities/report_models.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/reporting/metrics/comparison_calculator.dart';
import 'package:money_companion/domain/reporting/metrics/report_metrics_calculator.dart';

void main() {
  const calc = ReportMetricsCalculator();
  const cmp = ComparisonCalculator();

  group('computeCashFlow', () {
    test('typical month: net and savings rate', () {
      final m = calc.computeCashFlow(
          income: Money(1240000, 'SAR'), expense: Money(873000, 'SAR'));
      expect(m.net, Money(367000, 'SAR'));
      expect(m.savingsRate, closeTo(3670 / 12400, 1e-9));
    });

    test('zero income → savings rate is null (undefined), net is -expense', () {
      final m = calc.computeCashFlow(
          income: Money(0, 'SAR'), expense: Money(50000, 'SAR'));
      expect(m.savingsRate, isNull);
      expect(m.net, Money(-50000, 'SAR'));
    });

    test('zero expense → savings rate is 1.0', () {
      final m = calc.computeCashFlow(
          income: Money(100000, 'SAR'), expense: Money(0, 'SAR'));
      expect(m.savingsRate, closeTo(1.0, 1e-9));
      expect(m.net, Money(100000, 'SAR'));
    });

    test('overspend → negative net, savings rate clamped to 0', () {
      final m = calc.computeCashFlow(
          income: Money(100000, 'SAR'), expense: Money(150000, 'SAR'));
      expect(m.net, Money(-50000, 'SAR'));
      expect(m.savingsRate, 0.0);
    });

    test('extremely large amounts keep precision', () {
      final m = calc.computeCashFlow(
          income: Money(999999999999, 'SAR'),
          expense: Money(123456789012, 'SAR'));
      expect(m.net, Money(876543210987, 'SAR'));
    });

    test('per-currency computes one result per currency, never summed', () {
      final rows = calc.computePerCurrency([
        CurrencyTotal(
            currency: 'SAR',
            expense: Money(873000, 'SAR'),
            income: Money(1240000, 'SAR')),
        CurrencyTotal(
            currency: 'USD',
            expense: Money(20000, 'USD'),
            income: Money(0, 'USD')),
      ]);
      expect(rows.map((r) => r.currency).toList(), ['SAR', 'USD']);
      expect(rows[0].metrics.net, Money(367000, 'SAR'));
      expect(rows[1].metrics.savingsRate, isNull); // USD income 0
    });
  });

  group('comparison', () {
    test('expense dropped vs previous', () {
      final d = cmp.delta(Money(873000, 'SAR'), Money(991000, 'SAR'));
      expect(d.absolute, Money(-118000, 'SAR'));
      expect(d.percent, closeTo(-1180 / 9910, 1e-9));
      expect(d.isDecrease, isTrue);
    });

    test('percent is null when previous is zero', () {
      final d = cmp.delta(Money(10000, 'SAR'), Money(0, 'SAR'));
      expect(d.percent, isNull);
      expect(d.absolute, Money(10000, 'SAR'));
    });

    test('savings-rate delta is in percentage points', () {
      final current = calc.computeCashFlow(
          income: Money(1240000, 'SAR'), expense: Money(868000, 'SAR'));
      final previous = calc.computeCashFlow(
          income: Money(1240000, 'SAR'), expense: Money(992000, 'SAR'));
      final c = cmp.compare(current, previous);
      expect(c.savingsRatePoints, closeTo(0.10, 1e-9));
      expect(c.expense.isDecrease, isTrue);
    });

    test('savings-rate delta is null when a period is undefined', () {
      final current = calc.computeCashFlow(
          income: Money(100000, 'SAR'), expense: Money(50000, 'SAR'));
      final previous = calc.computeCashFlow(
          income: Money(0, 'SAR'), expense: Money(50000, 'SAR'));
      final c = cmp.compare(current, previous);
      expect(c.savingsRatePoints, isNull);
    });
  });
}
