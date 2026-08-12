import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/entities/budget_entity.dart';
import 'package:money_companion/domain/entities/engagement_entities.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/dashboard/home_sections_providers.dart';

BudgetEntity _budget({
  required String id,
  required String categoryId,
  required int amountMinor,
  String currency = 'SAR',
}) {
  return BudgetEntity(
    id: id,
    categoryId: categoryId,
    currency: currency,
    amountMoney: Money(amountMinor, currency),
    period: BudgetPeriod.monthly,
    startDate: DateTime(2026, 7),
    isActive: true,
    lastNotifiedSpentMoney: Money(0, currency),
    lastNotifiedPeriodStart: DateTime.utc(2000, 1, 1),
  );
}

BudgetProgressEntry _entry({
  required String categoryId,
  required int amountMinor,
  required int spentMinor,
  String currency = 'SAR',
}) {
  final budget = _budget(
    id: categoryId,
    categoryId: categoryId,
    amountMinor: amountMinor,
    currency: currency,
  );
  final spent = Money(spentMinor, currency);
  final remaining = budget.amountMoney - spent;
  final ratio = budget.amountMoney.isZero
      ? 0.0
      : spent.toDouble() / budget.amountMoney.toDouble();
  return BudgetProgressEntry(
    budget: budget,
    spent: spent,
    remaining: remaining,
    ratio: ratio,
    health: ratio >= 1
        ? BudgetHealth.over
        : (ratio >= 0.8 ? BudgetHealth.warning : BudgetHealth.safe),
    periodStart: DateTime(2026, 7),
    periodEnd: DateTime(2026, 7, 31),
  );
}

void main() {
  group('matchBudgetForCategory', () {
    test('returns the exact-category budget when one exists', () {
      final allExpenses = _entry(
        categoryId: BudgetEntity.allExpensesCategoryId,
        amountMinor: 50000,
        spentMinor: 10000,
      );
      final food =
          _entry(categoryId: 'food', amountMinor: 20000, spentMinor: 2000);
      final snapshot = BudgetProgressSnapshot(entries: [allExpenses, food]);

      final match = matchBudgetForCategory(snapshot, 'food', 'SAR');

      expect(match, same(food));
    });

    test('falls back to the all-expenses budget when no category match', () {
      final allExpenses = _entry(
        categoryId: BudgetEntity.allExpensesCategoryId,
        amountMinor: 50000,
        spentMinor: 10000,
      );
      final snapshot = BudgetProgressSnapshot(entries: [allExpenses]);

      final match = matchBudgetForCategory(snapshot, 'transport', 'SAR');

      expect(match, same(allExpenses));
    });

    test('returns null when there is no matching or catch-all budget', () {
      final food =
          _entry(categoryId: 'food', amountMinor: 20000, spentMinor: 2000);
      final snapshot = BudgetProgressSnapshot(entries: [food]);

      final match = matchBudgetForCategory(snapshot, 'transport', 'SAR');

      expect(match, isNull);
    });

    test('returns null for a null category id (uncategorized transaction)', () {
      final food =
          _entry(categoryId: 'food', amountMinor: 20000, spentMinor: 2000);
      final snapshot = BudgetProgressSnapshot(entries: [food]);

      final match = matchBudgetForCategory(snapshot, null, 'SAR');

      expect(match, isNull);
    });

    test('never matches a budget from another currency', () {
      final food = _entry(
        categoryId: 'food',
        amountMinor: 20000,
        spentMinor: 2000,
        currency: 'USD',
      );

      final match = matchBudgetForCategory(
        BudgetProgressSnapshot(entries: [food]),
        'food',
        'SAR',
      );

      expect(match, isNull);
    });
  });

  group('budgetContextText', () {
    test('pending/uncategorized transactions get the pending message', () {
      final text = budgetContextText(
        null,
        categoryName: 'الطعام',
        pending: true,
      );
      expect(text, 'عملية بانتظار التصنيف أو التأكيد');
    });

    test('no matching budget shows the neutral no-budget message', () {
      final text = budgetContextText(
        null,
        categoryName: 'الطعام',
      );
      expect(text, 'لا توجد ميزانية محددة لهذه الفئة');
    });

    test('remaining budget under 50% used shows the remaining amount', () {
      final entry =
          _entry(categoryId: 'food', amountMinor: 20000, spentMinor: 2000);
      final text = budgetContextText(
        entry,
        categoryName: 'الطعام',
      );
      expect(text, contains('متبقي'));
      expect(text, contains('180'));
      expect(text, contains('الطعام'));
    });

    test('50% or more used (but not exceeded) shows the usage percentage', () {
      final entry =
          _entry(categoryId: 'food', amountMinor: 20000, spentMinor: 13000);
      final text = budgetContextText(
        entry,
        categoryName: 'الطعام',
      );
      expect(text, contains('استخدمت'));
      expect(text, contains('65%'));
    });

    test('exceeded budget shows the exceeded amount', () {
      final entry =
          _entry(categoryId: 'food', amountMinor: 20000, spentMinor: 23000);
      final text = budgetContextText(
        entry,
        categoryName: 'الطعام',
      );
      expect(text, contains('تجاوزت'));
      expect(text, contains('30'));
    });
  });
}
