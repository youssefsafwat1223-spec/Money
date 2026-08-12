import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/entities/budget_entity.dart';
import 'package:money_companion/domain/entities/engagement_entities.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/services/budget_alert_planner.dart';

BudgetEntity _budget({
  String id = 'b1',
  String categoryId = 'food',
  double amount = 1000,
}) {
  return BudgetEntity(
    id: id,
    categoryId: categoryId,
    currency: 'SAR',
    amountMoney: Money.fromLegacyReal(amount, 'SAR'),
    period: BudgetPeriod.monthly,
    startDate: DateTime.utc(2026, 7),
    isActive: true,
    lastNotifiedSpentMoney: Money(0, 'SAR'),
    lastNotifiedPeriodStart: DateTime.utc(2026, 7),
  );
}

BudgetProgressEntry _entry({
  required double amount,
  required double spent,
  String id = 'b1',
  String categoryId = 'food',
}) {
  final budget = _budget(id: id, categoryId: categoryId, amount: amount);
  final ratio = amount == 0 ? 0.0 : spent / amount;
  return BudgetProgressEntry(
    budget: budget,
    spent: spent,
    remaining: amount - spent,
    ratio: ratio,
    health: ratio >= 1
        ? BudgetHealth.over
        : (ratio >= 0.8 ? BudgetHealth.warning : BudgetHealth.safe),
    periodStart: DateTime.utc(2026, 7),
    periodEnd: DateTime.utc(2026, 7, 31),
  );
}

void main() {
  const planner = BudgetAlertPlanner();
  final now = DateTime.utc(2026, 7, 15);

  test('no alert below 75% spent', () {
    final content = planner.plan(
      entry: _entry(amount: 1000, spent: 500),
      now: now,
      currencyLabel: 'ريال',
      categoryLabel: 'الطعام',
    );
    expect(content, isNull);
  });

  test('75%-89% spent produces a warning alert mentioning the category', () {
    final content = planner.plan(
      entry: _entry(amount: 1000, spent: 800),
      now: now,
      currencyLabel: 'ريال',
      categoryLabel: 'الطعام',
    );
    expect(content, isNotNull);
    expect(content!.type, NotificationType.budgetWarning);
    expect(content.title, contains('الطعام'));
  });

  test('90%-99% spent produces the "about to run out" warning', () {
    final content = planner.plan(
      entry: _entry(amount: 1000, spent: 950),
      now: now,
      currencyLabel: 'ريال',
      categoryLabel: 'الطعام',
    );
    expect(content, isNotNull);
    expect(content!.type, NotificationType.budgetWarning);
    expect(content.title, contains('على وشك الاكتمال'));
  });

  test('100%+ spent produces an over-budget alert', () {
    final content = planner.plan(
      entry: _entry(amount: 1000, spent: 1200),
      now: now,
      currencyLabel: 'ريال',
      categoryLabel: 'الطعام',
    );
    expect(content, isNotNull);
    expect(content!.type, NotificationType.budgetOver);
    expect(content.title, contains('تجاوزت'));
    expect(content.body, contains('200'));
  });

  test('different budgets produce different notification ids', () {
    final a = planner.plan(
      entry: _entry(id: 'b1', categoryId: 'food', amount: 1000, spent: 1200),
      now: now,
      currencyLabel: 'ريال',
      categoryLabel: 'الطعام',
    )!;
    final b = planner.plan(
      entry:
          _entry(id: 'b2', categoryId: 'transport', amount: 1000, spent: 1200),
      now: now,
      currencyLabel: 'ريال',
      categoryLabel: 'المواصلات',
    )!;
    expect(a.notifId, isNot(b.notifId));
  });

  test('same budget/period/bucket produces a stable notification id', () {
    final a = planner.plan(
      entry: _entry(amount: 1000, spent: 1200),
      now: now,
      currencyLabel: 'ريال',
      categoryLabel: 'الطعام',
    )!;
    final b = planner.plan(
      entry: _entry(amount: 1000, spent: 1300),
      now: now.add(const Duration(hours: 2)),
      currencyLabel: 'ريال',
      categoryLabel: 'الطعام',
    )!;
    expect(a.notifId, b.notifId);
  });
}
