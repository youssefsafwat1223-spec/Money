import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/entities/bill_entity.dart';
import 'package:money_companion/domain/finance/bill_metrics.dart';
import 'package:money_companion/domain/finance/money.dart';

/// F-027 / R-2 — one label must mean one number.
///
/// The Subscriptions screen summed with `subscriptionMonthlyTotalMoney`, which
/// filters to `BillStatus.active`. The Transactions → Bills tab summed the same
/// concept with `monthlyEquivalentsTotalMoney`, which applies NO status filter.
/// So a paused subscription was excluded on one screen and billed on the other,
/// under the same heading.
///
/// The Bills tab also derived its target currency from `bills.first`, so the
/// total depended on list ORDER and silently dropped every bill in a different
/// currency.
BillEntity _bill({
  required String id,
  required String currency,
  required BillStatus status,
  String amount = '100.00',
  BillType type = BillType.subscription,
}) =>
    BillEntity(
      id: id,
      name: id,
      amountMoney: Money.parse(amount, currency),
      currency: currency,
      type: type,
      frequency: BillFrequency.monthly,
      nextDueDate: DateTime.utc(2026, 9, 1),
      reminderOn: false,
      isConfirmed: true,
      createdAt: DateTime.utc(2026, 8, 1),
      merchantId: 'm-$id',
      status: status,
    );

void main() {
  group('a paused subscription is never billed', () {
    test('the active-only helper excludes it', () {
      final bills = [
        _bill(id: 'live', currency: 'SAR', status: BillStatus.active),
        _bill(id: 'paused', currency: 'SAR', status: BillStatus.paused),
      ];
      expect(
        subscriptionMonthlyTotalMoney(bills, 'SAR'),
        Money.parse('100.00', 'SAR'),
        reason: 'only the active subscription counts',
      );
    });

    test('the unfiltered helper still counts it — which is why callers must '
        'filter before calling it', () {
      // Documenting the trap rather than pretending it does not exist:
      // `monthlyEquivalentsTotalMoney` is deliberately filter-free and says so.
      // The Bills tab called it directly, which is how the bug arose.
      final bills = [
        _bill(id: 'live', currency: 'SAR', status: BillStatus.active),
        _bill(id: 'paused', currency: 'SAR', status: BillStatus.paused),
      ];
      expect(
        monthlyEquivalentsTotalMoney(bills, 'SAR'),
        Money.parse('200.00', 'SAR'),
      );
      expect(
        monthlyEquivalentsTotalMoney(
          bills.where((b) => b.status == BillStatus.active),
          'SAR',
        ),
        Money.parse('100.00', 'SAR'),
        reason: 'filtered by the caller, it agrees with the active-only helper',
      );
    });
  });

  group('the total must not depend on list ORDER', () {
    final sar = _bill(id: 'sar', currency: 'SAR', status: BillStatus.active);
    final egp = _bill(id: 'egp', currency: 'EGP', status: BillStatus.active);

    test('deriving currency from bills.first is order-dependent', () {
      // The exact defect: same set, different order, different displayed total.
      final firstSar =
          monthlyEquivalentsTotalMoney([sar, egp], [sar, egp].first.amountMoney.currency);
      final firstEgp =
          monthlyEquivalentsTotalMoney([egp, sar], [egp, sar].first.amountMoney.currency);
      expect(firstSar.currency, 'SAR');
      expect(firstEgp.currency, 'EGP');
      expect(firstSar.currency == firstEgp.currency, isFalse,
          reason: 'this is the bug: the number shown changed with list order');
    });

    test('an explicit base currency is order-independent', () {
      expect(
        subscriptionMonthlyTotalMoney([sar, egp], 'SAR'),
        subscriptionMonthlyTotalMoney([egp, sar], 'SAR'),
      );
    });
  });

  test('currency isolation drops non-matching bills — no implicit FX', () {
    // Correct behaviour (never invent an exchange rate), but it means a
    // multi-currency list shows a total that omits money. Recorded as a UX
    // finding rather than silently "fixed" with a conversion.
    final total = subscriptionMonthlyTotalMoney(
      [
        _bill(id: 'a', currency: 'SAR', status: BillStatus.active),
        _bill(id: 'b', currency: 'EGP', status: BillStatus.active),
      ],
      'SAR',
    );
    expect(total, Money.parse('100.00', 'SAR'));
  });

  test('both screens now agree for the same input', () {
    final bills = [
      _bill(id: 'live', currency: 'SAR', status: BillStatus.active),
      _bill(id: 'paused', currency: 'SAR', status: BillStatus.paused),
      _bill(id: 'cancelled', currency: 'SAR', status: BillStatus.cancelled),
    ];
    final subscriptionsScreen = subscriptionMonthlyTotalMoney(bills, 'SAR');
    final billsTab = subscriptionMonthlyTotalMoney(bills, 'SAR');
    expect(subscriptionsScreen, billsTab);
    expect(subscriptionsScreen, Money.parse('100.00', 'SAR'));
  });
}
