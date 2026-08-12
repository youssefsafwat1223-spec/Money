import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/entities/budget_entity.dart';
import 'package:money_companion/domain/entities/engagement_entities.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/dashboard/home_sections_providers.dart';

BudgetEntity _budget({
  required String id,
  required String categoryId,
  required double amount,
}) {
  return BudgetEntity(
    id: id,
    categoryId: categoryId,
    currency: 'SAR',
    amountMoney: Money.fromLegacyReal(amount, 'SAR'),
    period: BudgetPeriod.monthly,
    startDate: DateTime(2026, 7),
    isActive: true,
    lastNotifiedSpentMoney: Money(0, 'SAR'),
    lastNotifiedPeriodStart: DateTime.utc(2000, 1, 1),
  );
}

BudgetProgressEntry _entry({
  required String categoryId,
  required double amount,
  required double spent,
}) {
  final budget =
      _budget(id: categoryId, categoryId: categoryId, amount: amount);
  final remaining = amount - spent;
  final ratio = amount == 0 ? 0.0 : spent / amount;
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
        amount: 500,
        spent: 100,
      );
      final food = _entry(categoryId: 'food', amount: 200, spent: 20);
      final snapshot = BudgetProgressSnapshot(entries: [allExpenses, food]);

      final match = matchBudgetForCategory(snapshot, 'food');

      expect(match, same(food));
    });

    test('falls back to the all-expenses budget when no category match', () {
      final allExpenses = _entry(
        categoryId: BudgetEntity.allExpensesCategoryId,
        amount: 500,
        spent: 100,
      );
      final snapshot = BudgetProgressSnapshot(entries: [allExpenses]);

      final match = matchBudgetForCategory(snapshot, 'transport');

      expect(match, same(allExpenses));
    });

    test('returns null when there is no matching or catch-all budget', () {
      final food = _entry(categoryId: 'food', amount: 200, spent: 20);
      final snapshot = BudgetProgressSnapshot(entries: [food]);

      final match = matchBudgetForCategory(snapshot, 'transport');

      expect(match, isNull);
    });

    test('returns null for a null category id (uncategorized transaction)', () {
      final food = _entry(categoryId: 'food', amount: 200, spent: 20);
      final snapshot = BudgetProgressSnapshot(entries: [food]);

      final match = matchBudgetForCategory(snapshot, null);

      expect(match, isNull);
    });
  });

  group('budgetContextText', () {
    test('pending/uncategorized transactions get the pending message', () {
      final text = budgetContextText(
        null,
        categoryName: 'الطعام',
        currency: 'EGP',
        pending: true,
      );
      expect(text, 'عملية بانتظار التصنيف أو التأكيد');
    });

    test('no matching budget shows the neutral no-budget message', () {
      final text = budgetContextText(
        null,
        categoryName: 'الطعام',
        currency: 'EGP',
      );
      expect(text, 'لا توجد ميزانية محددة لهذه الفئة');
    });

    test('remaining budget under 50% used shows the remaining amount', () {
      final entry = _entry(categoryId: 'food', amount: 200, spent: 20);
      final text = budgetContextText(
        entry,
        categoryName: 'الطعام',
        currency: 'EGP',
      );
      expect(text, contains('متبقي'));
      expect(text, contains('180'));
      expect(text, contains('الطعام'));
    });

    test('50% or more used (but not exceeded) shows the usage percentage', () {
      final entry = _entry(categoryId: 'food', amount: 200, spent: 130);
      final text = budgetContextText(
        entry,
        categoryName: 'الطعام',
        currency: 'EGP',
      );
      expect(text, contains('استخدمت'));
      expect(text, contains('65%'));
    });

    test('exceeded budget shows the exceeded amount', () {
      final entry = _entry(categoryId: 'food', amount: 200, spent: 230);
      final text = budgetContextText(
        entry,
        categoryName: 'الطعام',
        currency: 'EGP',
      );
      expect(text, contains('تجاوزت'));
      expect(text, contains('30'));
    });
  });
}
