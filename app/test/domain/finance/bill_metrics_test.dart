import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/entities/bill_entity.dart';
import 'package:money_companion/domain/finance/bill_metrics.dart';
import 'package:money_companion/domain/finance/money.dart';

BillEntity bill({
  double amount = 30,
  Money? money,
  BillType type = BillType.subscription,
  BillFrequency frequency = BillFrequency.monthly,
  BillStatus status = BillStatus.active,
  int? customIntervalDays,
  int? totalInstallments,
  int? paidCount,
  String currency = 'SAR',
}) {
  final amt = money ?? Money.fromLegacyReal(amount, currency);
  return BillEntity(
    id: 'b',
    name: 'n',
    amountMoney: amt,
    currency: amt.currency,
    type: type,
    frequency: frequency,
    nextDueDate: DateTime(2026, 7, 1),
    reminderOn: false,
    isConfirmed: true,
    createdAt: DateTime(2026, 7, 1),
    status: status,
    customIntervalDays: customIntervalDays,
    totalInstallments: totalInstallments,
    paidCount: paidCount,
  );
}

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

  // MALI-026 closure: a displayed monetary total is a financial aggregate — it
  // is summed EXACTLY as Money (integer minor units), currency-isolated, and
  // converted to double ONLY at the leaf display. No intermediate double fold.
  group('subscriptionMonthlyTotalMoney', () {
    test('same-currency exact sum of active subscriptions only', () {
      final bills = [
        bill(amount: 30, frequency: BillFrequency.monthly), // 30
        bill(amount: 120, frequency: BillFrequency.yearly), // 10 / month
        bill(
            amount: 10,
            frequency: BillFrequency.monthly,
            status: BillStatus.paused), // excluded (not active)
        bill(
            amount: 99,
            type: BillType.installment), // excluded (not a subscription)
      ];
      expect(subscriptionMonthlyTotalMoney(bills, 'SAR'),
          Money.parse('40', 'SAR')); // 30 + 10, exact
    });

    test('cents sum exactly where a double fold would drift (0.10 + 0.20)', () {
      final bills = [
        bill(money: Money.parse('0.10', 'SAR')),
        bill(money: Money.parse('0.20', 'SAR')),
      ];
      // exact 0.30 (30 minor), never 0.30000000000000004.
      expect(subscriptionMonthlyTotalMoney(bills, 'SAR'),
          Money.parse('0.30', 'SAR'));
    });

    test('3-decimal currency (KWD) sums at 3-dp scale', () {
      final bills = [
        bill(money: Money.parse('1.005', 'KWD')),
        bill(money: Money.parse('2.005', 'KWD')),
      ];
      final total = subscriptionMonthlyTotalMoney(bills, 'KWD');
      expect(total, Money.parse('3.010', 'KWD'));
      expect(total.minorUnits, 3010); // 1005 + 2005
    });

    test('sum beyond 2^53 minor stays exact (BigInt accumulation)', () {
      // 90071992547409.93 SAR = 9007199254740993 minor = 2^53 + 1.
      final big = Money.parse('90071992547409.93', 'SAR');
      expect(big.minorUnits, 9007199254740993);
      final bills = [bill(money: big), bill(money: big)];
      expect(subscriptionMonthlyTotalMoney(bills, 'SAR').minorUnits,
          18014398509481986); // 2 × (2^53 + 1), exact
    });

    test('never folds a mixed currency: only the requested currency is summed',
        () {
      final bills = [
        bill(money: Money.parse('100', 'SAR')),
        bill(money: Money.parse('50', 'KWD')),
      ];
      expect(subscriptionMonthlyTotalMoney(bills, 'SAR'),
          Money.parse('100', 'SAR'));
      expect(subscriptionMonthlyTotalMoney(bills, 'KWD'),
          Money.parse('50', 'KWD'));
    });

    test('returns an exact Money total; the display double is derived AFTER',
        () {
      final bills = [
        bill(money: Money.parse('19.99', 'SAR')),
        bill(money: Money.parse('19.99', 'SAR')),
      ];
      final total = subscriptionMonthlyTotalMoney(bills, 'SAR');
      expect(total, isA<Money>()); // exact total exists first
      expect(total, Money.parse('39.98', 'SAR'));
      expect(total.toDouble(), 39.98); // leaf conversion only after
    });
  });

  group('installmentsRemainingTotalMoney', () {
    test('same-currency exact sum of amount × remainingInstallments', () {
      final bills = [
        bill(
            money: Money.parse('100', 'SAR'),
            type: BillType.installment,
            totalInstallments: 12,
            paidCount: 2), // 100 × 10 = 1000
        bill(
            money: Money.parse('50', 'SAR'),
            type: BillType.installment,
            totalInstallments: 6,
            paidCount: 1), // 50 × 5 = 250
      ];
      expect(installmentsRemainingTotalMoney(bills, 'SAR'),
          Money.parse('1250', 'SAR'));
    });

    test('3-decimal currency, cents-exact', () {
      final bills = [
        bill(
            money: Money.parse('0.005', 'KWD'),
            type: BillType.installment,
            totalInstallments: 3,
            paidCount: 0), // 0.005 × 3 = 0.015
      ];
      expect(installmentsRemainingTotalMoney(bills, 'KWD'),
          Money.parse('0.015', 'KWD'));
    });

    test('sum beyond 2^53 minor stays exact', () {
      final big = Money.parse('90071992547409.93', 'SAR'); // 2^53 + 1 minor
      final bills = [
        bill(
            money: big,
            type: BillType.installment,
            totalInstallments: 2,
            paidCount: 0), // × 2
      ];
      expect(installmentsRemainingTotalMoney(bills, 'SAR').minorUnits,
          18014398509481986);
    });

    test('currency-isolated: a KWD installment is never folded into SAR', () {
      final bills = [
        bill(
            money: Money.parse('100', 'SAR'),
            type: BillType.installment,
            totalInstallments: 5,
            paidCount: 0), // 500 SAR
        bill(
            money: Money.parse('30', 'KWD'),
            type: BillType.installment,
            totalInstallments: 4,
            paidCount: 0), // 120 KWD
      ];
      expect(installmentsRemainingTotalMoney(bills, 'SAR'),
          Money.parse('500', 'SAR'));
      expect(installmentsRemainingTotalMoney(bills, 'KWD'),
          Money.parse('120', 'KWD'));
    });

    test('returns exact Money; the display double is derived AFTER', () {
      final bills = [
        bill(
            money: Money.parse('19.99', 'SAR'),
            type: BillType.installment,
            totalInstallments: 2,
            paidCount: 0), // 39.98
      ];
      final total = installmentsRemainingTotalMoney(bills, 'SAR');
      expect(total, isA<Money>());
      expect(total, Money.parse('39.98', 'SAR'));
      expect(total.toDouble(), 39.98);
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
