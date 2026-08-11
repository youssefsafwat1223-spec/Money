import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/sync/sync_cursor.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/planning_sync/services/planning_pull_service.dart';

void main() {
  test('planning pull request shape casts only subscriptions and plans money',
      () {
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

    for (final table in ['user_budgets', 'user_goals']) {
      final select = planningPullSelectForTable(table);
      expect(select, '*', reason: '$table must keep its STOP-gated select');
      expect(select, isNot(contains('::text')));
    }
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
}
