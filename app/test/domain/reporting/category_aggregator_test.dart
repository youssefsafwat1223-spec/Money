import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/entities/category_spend.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/reporting/metrics/category_aggregator.dart';

void main() {
  const agg = CategoryAggregator();

  // Resolver: a/b known, "gone" is a deleted category (returns null).
  String? labelFor(String id) => const {'a': 'A', 'b': 'B'}[id];

  test('ranks by total and adds an Other remainder so shares sum to 100%', () {
    final slices = agg.aggregate(
      breakdown: [
        CategorySpend(categoryId: 'b', total: Money(100000, 'SAR'), count: 3),
        CategorySpend(categoryId: 'a', total: Money(200000, 'SAR'), count: 5),
        CategorySpend(categoryId: 'gone', total: Money(50000, 'SAR'), count: 2),
      ],
      labelFor: labelFor,
      totalExpense: Money(400000, 'SAR'),
      otherLabel: 'Other',
    );

    // A (2000), B (1000), Other (4000 - 3000 resolved = 1000)
    expect(slices.map((s) => s.label).toList(), ['A', 'B', 'Other']);
    expect(slices.first.total, Money(200000, 'SAR')); // sorted desc
    final other = slices.last;
    expect(other.isOther, isTrue);
    expect(other.categoryId, isNull);
    expect(other.total, Money(100000, 'SAR'));

    final sumPercent = slices.fold<double>(0, (s, x) => s + x.percent);
    expect(sumPercent, closeTo(1.0, 1e-9));
  });

  test('no Other row when categories already account for the whole total', () {
    final slices = agg.aggregate(
      breakdown: [
        CategorySpend(categoryId: 'a', total: Money(300000, 'SAR'), count: 1),
        CategorySpend(categoryId: 'b', total: Money(100000, 'SAR'), count: 1),
      ],
      labelFor: labelFor,
      totalExpense: Money(400000, 'SAR'),
      otherLabel: 'Other',
    );
    expect(slices.any((s) => s.isOther), isFalse);
    expect(slices.map((s) => s.label).toList(), ['A', 'B']);
  });

  test('zero total expense yields zero percents and no Other', () {
    final slices = agg.aggregate(
      breakdown: const [],
      labelFor: labelFor,
      totalExpense: Money(0, 'SAR'),
      otherLabel: 'Other',
    );
    expect(slices, isEmpty);
  });

  test('all-deleted categories collapse into a single Other row', () {
    final slices = agg.aggregate(
      breakdown: [
        CategorySpend(categoryId: 'gone', total: Money(30000, 'SAR'), count: 1),
        CategorySpend(
            categoryId: 'gone2', total: Money(20000, 'SAR'), count: 1),
      ],
      labelFor: labelFor, // both unknown
      totalExpense: Money(50000, 'SAR'),
      otherLabel: 'Other',
    );
    expect(slices.length, 1);
    expect(slices.single.isOther, isTrue);
    expect(slices.single.total, Money(50000, 'SAR'));
    expect(slices.single.percent, closeTo(1.0, 1e-9));
  });
}
