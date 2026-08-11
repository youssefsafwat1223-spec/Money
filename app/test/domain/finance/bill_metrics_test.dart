import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/entities/bill_entity.dart';
import 'package:money_companion/domain/finance/bill_metrics.dart';
import 'package:money_companion/domain/finance/money.dart';

BillEntity bill({
  double amount = 30,
  BillType type = BillType.subscription,
  BillFrequency frequency = BillFrequency.monthly,
  BillStatus status = BillStatus.active,
  int? customIntervalDays,
  String currency = 'SAR',
}) =>
    BillEntity(
      id: 'b',
      name: 'n',
      amountMoney: Money.fromLegacyReal(amount, currency),
      currency: currency,
      type: type,
      frequency: frequency,
      nextDueDate: DateTime(2026, 7, 1),
      reminderOn: false,
      isConfirmed: true,
      createdAt: DateTime(2026, 7, 1),
      status: status,
      customIntervalDays: customIntervalDays,
    );

BillPaymentEntity payment(double amount,
        {String? transactionId, String id = 'p'}) =>
    BillPaymentEntity(
      id: id,
      billId: 'b',
      amountMoney: Money.fromLegacyReal(amount, 'SAR'),
      currency: 'SAR',
      periodStart: DateTime(2026, 7, 1),
      periodEnd: DateTime(2026, 8, 1),
      paidAt: DateTime(2026, 7, 5),
      transactionId: transactionId,
    );

void main() {
  group('recurrence normalization', () {
    test('annualEquivalent per frequency', () {
      expect(
          annualEquivalent(bill(amount: 10, frequency: BillFrequency.weekly)),
          520);
      expect(
          annualEquivalent(bill(amount: 10, frequency: BillFrequency.monthly)),
          120);
      expect(
          annualEquivalent(bill(amount: 10, frequency: BillFrequency.yearly)),
          10);
      expect(
        annualEquivalent(bill(
            amount: 10,
            frequency: BillFrequency.custom,
            customIntervalDays: 73)),
        closeTo(50, 1e-9), // 10 * 365/73
      );
    });

    test('custom recurrence quantizes once through exact Money arithmetic', () {
      final result = annualEquivalentMoney(
        bill(
          amount: 1,
          currency: 'KWD',
          frequency: BillFrequency.custom,
          customIntervalDays: 7,
        ),
      );

      expect(result, Money(52143, 'KWD'));
    });

    test('monthlyEquivalent uses the exact annual Money ratio', () {
      for (final f in BillFrequency.values) {
        final b = bill(amount: 12, frequency: f, customIntervalDays: 30);
        final expected = annualEquivalentMoney(b).applyRate(
          rateNumerator: BigInt.one,
          rateDenominator: BigInt.from(12),
        );
        expect(monthlyEquivalentMoney(b), expected);
        expect(monthlyEquivalent(b), expected.toDouble());
      }
    });
  });

  group('subscriptionMonthlyTotal', () {
    test('sums monthly-equivalent of active subscriptions only', () {
      final bills = [
        bill(amount: 30, frequency: BillFrequency.monthly), // 30
        bill(amount: 120, frequency: BillFrequency.yearly), // 10
        bill(
            amount: 10,
            frequency: BillFrequency.monthly,
            status: BillStatus.paused), // excluded
        bill(
            amount: 99,
            type: BillType.installment), // excluded (not a subscription)
      ];
      expect(subscriptionMonthlyTotal(bills), 40); // 30 + 10
    });
  });

  group('billPaidTotal attribution', () {
    test('recorded payments count once; fuzzy transactions never sum', () {
      // A payment linked to a transaction is ONE payment in the ledger.
      final summary = billPaidTotal(
        payments: [payment(50, transactionId: 'tx1')],
        manualPaidMoney: Money.zero('SAR'),
      );
      expect(summary.recorded, 50);
      expect(summary.total, 50); // not 100, even though tx1 also exists
    });

    test('legacy manual only fills the residual beyond recorded', () {
      expect(
        billPaidTotal(
          payments: [payment(30)],
          manualPaidMoney: Money.parse('50', 'SAR'),
        ).total,
        50,
      ); // 30 + 20
      expect(
        billPaidTotal(
          payments: [payment(80)],
          manualPaidMoney: Money.parse('50', 'SAR'),
        ).total,
        80,
      ); // recorded >= manual
      expect(
        billPaidTotal(
          payments: const [],
          manualPaidMoney: Money.parse('50', 'SAR'),
        ).total,
        50,
      ); // pure legacy
      expect(
        billPaidTotal(
          payments: const [],
          manualPaidMoney: Money.zero('SAR'),
        ).total,
        0,
      ); // nothing
    });

    test('partial and overpayment are the recorded amounts', () {
      expect(
        billPaidTotal(
          payments: [payment(20)],
          manualPaidMoney: Money.zero('SAR'),
        ).total,
        20,
      );
      expect(
        billPaidTotal(
          payments: [payment(200)],
          manualPaidMoney: Money.zero('SAR'),
        ).total,
        200,
      );
    });

    test('linkedTransactionIds separates linked from suggestion', () {
      final payments = [
        payment(50, transactionId: 'tx1', id: 'p1'),
        payment(50, id: 'p2'), // manual, no transaction
      ];
      expect(linkedTransactionIds(payments), {'tx1'});
      // A fuzzy list [tx1, tx2] → only tx2 is an unlinked suggestion.
      final fuzzy = ['tx1', 'tx2'];
      final suggestions =
          fuzzy.where((id) => !linkedTransactionIds(payments).contains(id));
      expect(suggestions, ['tx2']);
    });
  });
}
