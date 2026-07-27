import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/entities/category_spend.dart';
import 'package:money_companion/domain/reporting/metrics/category_aggregator.dart';

void main() {
  const agg = CategoryAggregator();

  // Resolver: a/b known, "gone" is a deleted category (returns null).
  String? labelFor(String id) => const {'a': 'A', 'b': 'B'}[id];

  test('ranks by total and adds an Other remainder so shares sum to 100%', () {
    final slices = agg.aggregate(
      breakdown: const [
        CategorySpend(categoryId: 'b', total: 1000, count: 3),
        CategorySpend(categoryId: 'a', total: 2000, count: 5),
        CategorySpend(categoryId: 'gone', total: 500, count: 2), // deleted
      ],
      labelFor: labelFor,
      totalExpense: 4000, // includes 1000 of uncategorised/other
      otherLabel: 'Other',
    );

    // A (2000), B (1000), Other (4000 - 3000 resolved = 1000)
    expect(slices.map((s) => s.label).toList(), ['A', 'B', 'Other']);
    expect(slices.first.total, 2000); // sorted desc
    final other = slices.last;
    expect(other.isOther, isTrue);
    expect(other.categoryId, isNull);
    expect(other.total, closeTo(1000, 1e-9)); // deleted 500 + uncategorised 500

    final sumPercent = slices.fold<double>(0, (s, x) => s + x.percent);
    expect(sumPercent, closeTo(1.0, 1e-9));
  });

  test('no Other row when categories already account for the whole total', () {
    final slices = agg.aggregate(
      breakdown: const [
        CategorySpend(categoryId: 'a', total: 3000, count: 1),
        CategorySpend(categoryId: 'b', total: 1000, count: 1),
      ],
      labelFor: labelFor,
      totalExpense: 4000,
      otherLabel: 'Other',
    );
    expect(slices.any((s) => s.isOther), isFalse);
    expect(slices.map((s) => s.label).toList(), ['A', 'B']);
  });

  test('zero total expense yields zero percents and no Other', () {
    final slices = agg.aggregate(
      breakdown: const [],
      labelFor: labelFor,
      totalExpense: 0,
      otherLabel: 'Other',
    );
    expect(slices, isEmpty);
  });

  test('all-deleted categories collapse into a single Other row', () {
    final slices = agg.aggregate(
      breakdown: const [
        CategorySpend(categoryId: 'gone', total: 300, count: 1),
        CategorySpend(categoryId: 'gone2', total: 200, count: 1),
      ],
      labelFor: labelFor, // both unknown
      totalExpense: 500,
      otherLabel: 'Other',
    );
    expect(slices.length, 1);
    expect(slices.single.isOther, isTrue);
    expect(slices.single.total, closeTo(500, 1e-9));
    expect(slices.single.percent, closeTo(1.0, 1e-9));
  });
}
