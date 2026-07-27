import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/reporting/insights/insight_engine.dart';

void main() {
  const engine = InsightEngine();

  test('fires spending-decreased and savings-improved as successes', () {
    final out = engine.evaluate(const InsightInput(
      expenseDeltaPct: -0.119,
      savingsPointsDelta: 0.10,
    ));
    final codes = out.map((i) => i.code).toSet();
    expect(codes, containsAll(<InsightCode>[
      InsightCode.spendingDecreased,
      InsightCode.savingsImproved,
    ]));
    expect(out.every((i) => i.severity == InsightSeverity.success), isTrue);
  });

  test('ignores changes below threshold', () {
    final out = engine.evaluate(const InsightInput(
      expenseDeltaPct: 0.03, // < 10%
      savingsPointsDelta: 0.01, // < 5pp
    ));
    expect(out, isEmpty);
  });

  test('over-budget is a danger and ranks first', () {
    final out = engine.evaluate(const InsightInput(
      overBudgetCount: 2,
      dominantCategoryLabel: 'Groceries',
      dominantCategoryShare: 0.45,
      expenseDeltaPct: -0.2,
    ));
    expect(out.first.code, InsightCode.budgetsOver);
    expect(out.first.severity, InsightSeverity.danger);
    expect(out.map((i) => i.code), contains(InsightCode.dominantCategory));
  });

  test('dominant category only fires at/above 40%', () {
    expect(
      engine
          .evaluate(const InsightInput(
              dominantCategoryLabel: 'X', dominantCategoryShare: 0.39))
          .where((i) => i.code == InsightCode.dominantCategory),
      isEmpty,
    );
    expect(
      engine
          .evaluate(const InsightInput(
              dominantCategoryLabel: 'X', dominantCategoryShare: 0.40))
          .where((i) => i.code == InsightCode.dominantCategory),
      isNotEmpty,
    );
  });

  test('bill-due only fires within the due-soon window', () {
    expect(
      engine
          .evaluate(const InsightInput(dueBillName: 'Netflix', dueBillInDays: 30))
          .where((i) => i.code == InsightCode.billDueSoon),
      isEmpty,
    );
    final soon = engine.evaluate(
        const InsightInput(dueBillName: 'Netflix', dueBillInDays: 3));
    expect(soon.first.code, InsightCode.billDueSoon);
  });

  test('caps at 8 insights, most-severe first', () {
    final out = engine.evaluate(const InsightInput(
      expenseDeltaPct: 0.5,
      savingsPointsDelta: -0.2,
      overBudgetCount: 3,
      dominantCategoryLabel: 'X',
      dominantCategoryShare: 0.6,
      dueBillName: 'Rent',
      dueBillInDays: 2,
      hasUnusualDay: true,
    ));
    expect(out.length, lessThanOrEqualTo(8));
    expect(out.first.severity, InsightSeverity.danger);
  });
}
