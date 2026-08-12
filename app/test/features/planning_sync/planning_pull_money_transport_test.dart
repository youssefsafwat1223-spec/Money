import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/sync/sync_cursor.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/finance/money_transport.dart';
import 'package:money_companion/features/planning_sync/services/planning_pull_service.dart';

void main() {
  test('planning pull request shape casts money for every canonical planning '
      'table (subscriptions, plans, budgets, goals)', () {
    expect(
      planningPullSelectForTable('user_subscriptions'),
      allOf(
        contains('amount_text:amount::text'),
        contains('manual_paid_amount_text:manual_paid_amount::text'),
        contains('total_purchase_amount_text:total_purchase_amount::text'),
      ),
    );
    expect(
      planningPullSelectForTable('user_plans'),
      contains('budget_amount_text:budget_amount::text'),
    );
    // MALI-026 (B8-3 §9): budgets/goals now project every NUMERIC money column as
    // ::text so the pull is exact (still capability-gated at the service level).
    expect(
      planningPullSelectForTable('user_budgets'),
      allOf(
        contains('amount_text:amount::text'),
        contains(
            'last_notified_spent_amount_text:last_notified_spent_amount::text'),
      ),
    );
    expect(
      planningPullSelectForTable('user_goals'),
      allOf(
        contains('target_amount_text:target_amount::text'),
        contains('saved_amount_text:saved_amount::text'),
        contains(
            'last_notified_saved_amount_text:last_notified_saved_amount::text'),
        contains('auto_save_amount_text:auto_save_amount::text'),
      ),
    );
    // Entities with no money keep the plain select.
    expect(planningPullSelectForTable('user_cards'), '*');

    expect(planningPullOrderColumns, ['updated_at', 'id']);
    final filter = planningPullKeysetFilter(
      const SyncCursor(
        updatedAt: '2026-01-01T00:00:00Z',
        id: 'planning-row-1',
      ),
    );
    expect(filter, contains('updated_at.gt.'));
    expect(filter, contains('updated_at.eq.'));
    expect(filter, contains('id.gt.planning-row-1'));
    expect(filter, isNot(contains('_text')),
        reason: 'keyset filtering must use original server columns');
  });

  test('subscriptions and plans deserialize exact nullable money text', () {
    final subscriptionMoney = deserializeSubscriptionsPullMoney({
      'currency': 'EGP',
      'amount_text': '90071992547409.93',
      'manual_paid_amount_text': null,
      'total_purchase_amount_text': '12.34',
    });
    expect(
      subscriptionMoney.amountMoney,
      Money(9007199254740993, 'EGP'),
    );
    expect(subscriptionMoney.manualPaidMoney, isNull);
    expect(subscriptionMoney.totalPurchaseMoney, Money(1234, 'EGP'));

    expect(
      deserializePlansPullMoney({
        'currency': 'JPY',
        'budget_amount_text': '9007199254740993',
      }),
      Money(9007199254740993, 'JPY'),
    );
    expect(
      deserializePlansPullMoney({
        'currency': 'JPY',
        'budget_amount_text': null,
      }),
      isNull,
    );
  });

  test('budgets/goals deserialize exact money from ::text with the row currency',
      () {
    final budget = deserializeBudgetsPullMoney({
      'currency': 'EGP',
      'amount_text': '90071992547409.93', // > 2^53 minor
      'last_notified_spent_amount_text': '0',
    });
    expect(budget.amountMoney, Money(9007199254740993, 'EGP'));
    expect(budget.lastNotifiedSpentMoney, Money(0, 'EGP'));

    final goal = deserializeGoalsPullMoney({
      'currency': 'KWD', // 3-decimal
      'target_amount_text': '1.005',
      'saved_amount_text': '0.250',
      'last_notified_saved_amount_text': '0',
      'auto_save_amount_text': null, // nullable
    });
    expect(goal.targetMoney, Money(1005, 'KWD'));
    expect(goal.savedMoney, Money(250, 'KWD'));
    expect(goal.lastNotifiedSavedMoney, Money(0, 'KWD'));
    expect(goal.autoSaveMoney, isNull);
  });

  test('budget/goal pull fails closed when the ::text projection is missing', () {
    // A JSON number (cast not applied) must throw, never silently degrade.
    expect(
      () => deserializeBudgetsPullMoney({
        'currency': 'EGP',
        'amount_text': 12.34,
        'last_notified_spent_amount_text': '0',
      }),
      throwsA(isA<MoneyTransportException>()),
    );
    // A missing currency must throw.
    expect(
      () => deserializeGoalsPullMoney({
        'target_amount_text': '1.00',
        'saved_amount_text': '0',
        'last_notified_saved_amount_text': '0',
        'auto_save_amount_text': null,
      }),
      throwsA(isA<MoneyTransportException>()),
    );
  });
}
