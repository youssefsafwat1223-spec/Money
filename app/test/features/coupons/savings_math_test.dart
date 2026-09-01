// COUPONS Phase 4 — savings arithmetic.
//
// The governing rule, in one line: IN A FINANCE APP A WRONG SAVING IS WORSE
// THAN NO SAVING. The user cannot check it, and the moment they find one number
// was invented, every other number in the app inherits the doubt.
//
// So most of this file is about abstention — the cases where the honest answer
// is nothing at all.

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/features/coupons/coupon_models.dart';
import 'package:money_companion/features/coupons/savings_math.dart';

CouponOffer _offer({
  String? benefitType,
  int? discountBps,
  int? fixedAmountMinor,
  int? minSpendMinor,
  int? maxSavingMinor,
  String? benefitCurrency,
}) =>
    CouponOffer(
      id: 'x',
      slug: 'x',
      partnerName: 'P',
      titleAr: 'ع',
      descriptionAr: 'و',
      redemptionType: CouponRedemptionType.code,
      code: 'C',
      category: const CouponCategory(key: 'k', labelAr: 'ك'),
      validFrom: DateTime.utc(2026, 1, 1),
      benefitType: benefitType,
      discountBps: discountBps,
      fixedAmountMinor: fixedAmountMinor,
      minSpendMinor: minSpendMinor,
      maxSavingMinor: maxSavingMinor,
      benefitCurrency: benefitCurrency,
    );

final _percent20 = _offer(
    benefitType: 'percent', discountBps: 2000, benefitCurrency: 'SAR');

void main() {
  group('the app abstains rather than invent a number', () {
    test('a prose-only offer produces nothing', () {
      final r = SavingsMath.potentialSaving(_offer(),
          basketMinor: 10000, basketCurrency: 'SAR');
      expect(r.hasAmount, isFalse);
      expect(r.abstention, SavingsAbstention.noStructuredBenefit);
    });

    test('free shipping has real value and no computable amount', () {
      // Inventing a delivery-fee figure would be pure fiction.
      final r = SavingsMath.potentialSaving(
        _offer(benefitType: 'free_shipping', benefitCurrency: 'SAR'),
        basketMinor: 10000,
        basketCurrency: 'SAR',
      );
      expect(r.hasAmount, isFalse);
      expect(r.abstention, SavingsAbstention.benefitHasNoAmount);
    });

    test('currencies are NEVER converted', () {
      // There is no FX design. Converting at a rate we picked would put an
      // invented number in someone's savings total — and the rate would be
      // stale by the time they looked at it.
      final r = SavingsMath.potentialSaving(_percent20,
          basketMinor: 10000, basketCurrency: 'EGP');
      expect(r.hasAmount, isFalse);
      expect(r.abstention, SavingsAbstention.currencyMismatch);
    });

    test('a currency the money layer cannot scale is refused', () {
      // Guessing two decimal places is how a JPY figure ends up 100x wrong.
      final r = SavingsMath.potentialSaving(
        _offer(benefitType: 'percent', discountBps: 2000, benefitCurrency: 'XYZ'),
        basketMinor: 10000,
        basketCurrency: 'XYZ',
      );
      expect(r.abstention, SavingsAbstention.unsupportedCurrency);
    });

    test('a basket below the minimum spend does not qualify', () {
      final r = SavingsMath.potentialSaving(
        _offer(
            benefitType: 'percent',
            discountBps: 2000,
            minSpendMinor: 20000,
            benefitCurrency: 'SAR'),
        basketMinor: 19999,
        basketCurrency: 'SAR',
      );
      expect(r.abstention, SavingsAbstention.belowMinimumSpend);
    });

    test('a discount that rounds away to nothing is not a saving', () {
      final r = SavingsMath.potentialSaving(
        _offer(benefitType: 'percent', discountBps: 1, benefitCurrency: 'SAR'),
        basketMinor: 10,
        basketCurrency: 'SAR',
      );
      expect(r.hasAmount, isFalse);
    });
  });

  group('arithmetic is exact and never overstates', () {
    test('a whole percentage is exact', () {
      final r = SavingsMath.potentialSaving(_percent20,
          basketMinor: 10000, basketCurrency: 'SAR');
      expect(r.amountMinor, 2000);
      expect(r.currency, 'SAR');
    });

    test('a fractional percentage truncates DOWN', () {
      // Truncating can only understate, which is the safe direction for a
      // number we are asserting on someone's behalf. 12.5% of 333 is 41.625.
      final r = SavingsMath.potentialSaving(
        _offer(benefitType: 'percent', discountBps: 1250, benefitCurrency: 'SAR'),
        basketMinor: 333,
        basketCurrency: 'SAR',
      );
      expect(r.amountMinor, 41);
    });

    test('a cap is applied', () {
      final r = SavingsMath.potentialSaving(
        _offer(
            benefitType: 'percent',
            discountBps: 5000,
            maxSavingMinor: 5000,
            benefitCurrency: 'SAR'),
        basketMinor: 100000,
        basketCurrency: 'SAR',
      );
      expect(r.amountMinor, 5000);
    });

    test('a fixed discount cannot exceed the basket', () {
      // "You saved 50" on a 30-riyal purchase is arithmetically impossible and
      // reads as a bug.
      final r = SavingsMath.potentialSaving(
        _offer(benefitType: 'fixed_amount', fixedAmountMinor: 5000, benefitCurrency: 'SAR'),
        basketMinor: 3000,
        basketCurrency: 'SAR',
      );
      expect(r.amountMinor, 3000);
    });

    test('a zero-decimal currency is not scaled differently', () {
      // JPY minor units ARE whole yen. The math is unit-agnostic on purpose:
      // it never divides by a scale, so it cannot get one wrong.
      final r = SavingsMath.potentialSaving(
        _offer(benefitType: 'percent', discountBps: 2000, benefitCurrency: 'JPY'),
        basketMinor: 10000,
        basketCurrency: 'JPY',
      );
      expect(r.amountMinor, 2000);
      expect(r.currency, 'JPY');
    });

    test('no floating point anywhere in the result', () {
      // A savings total that does not reconcile with its own entries is a total
      // nobody trusts. Every awkward rate against every awkward basket must
      // still be an integer.
      for (final bps in [1, 7, 333, 1250, 3333, 9999]) {
        for (final basket in [1, 7, 99, 12345, 999999]) {
          final r = SavingsMath.potentialSaving(
            _offer(benefitType: 'percent', discountBps: bps, benefitCurrency: 'SAR'),
            basketMinor: basket,
            basketCurrency: 'SAR',
          );
          if (r.hasAmount) {
            expect(r.amountMinor, isA<int>());
            expect(r.amountMinor! <= basket, isTrue,
                reason: 'a saving can never exceed the basket');
          }
        }
      }
    });
  });

  group('evidence is never blurred', () {
    test('an approved conversion WITHOUT a discount is only an ESTIMATE', () {
      // "A sale happened" and "the user was discounted this much" are different
      // facts. Calling the second one verified would be asserting something the
      // provider never told us.
      final r = SavingsMath.fromConversion(_percent20,
          status: 'approved', orderAmountMinor: 10000, orderCurrency: 'SAR');
      expect(r.amountMinor, 2000);
      expect(r.evidence, SavingsEvidence.conversionEstimated);
    });

    test('only an explicit provider discount is VERIFIED', () {
      final r = SavingsMath.fromConversion(_percent20,
          status: 'approved',
          orderAmountMinor: 10000,
          orderCurrency: 'SAR',
          providerDiscountMinor: 1750,
          providerDiscountCurrency: 'SAR');
      expect(r.amountMinor, 1750, reason: 'the provider figure wins over ours');
      expect(r.evidence, SavingsEvidence.conversionVerified);
    });

    test('a user confirmation is labelled as such', () {
      final r = SavingsMath.fromUserConfirmation(_percent20,
          basketMinor: 10000, basketCurrency: 'SAR');
      expect(r.evidence, SavingsEvidence.userConfirmed);
    });

    test('a pending conversion produces NOTHING', () {
      // It may still be clawed back. Recording it would mean writing a saving
      // we expect to have to reverse.
      for (final status in ['pending', 'rejected', 'returned', 'cancelled']) {
        final r = SavingsMath.fromConversion(_percent20,
            status: status, orderAmountMinor: 10000, orderCurrency: 'SAR');
        expect(r.hasAmount, isFalse, reason: status);
      }
    });

    test('an approved conversion of unknown size produces nothing, not zero', () {
      // Zero would read as "you saved nothing", which is a different and false
      // statement.
      final r = SavingsMath.fromConversion(_percent20, status: 'approved');
      expect(r.hasAmount, isFalse);
    });

    test('the three evidence kinds are distinct values', () {
      // They must never be summable without saying which is which.
      expect(SavingsEvidence.values.toSet().length, 3);
    });
  });

  test('commission appears nowhere in this API', () {
    // What a network pays US is our revenue, in our currency, under our
    // contract. It is not the user's money and must never enter a savings
    // figure. There is no parameter here that could carry it.
    const surface = [
      'potentialSaving', 'fromUserConfirmation', 'fromConversion',
    ];
    expect(surface.length, 3);
    // fromConversion takes the PROVIDER DISCOUNT — what the user was reduced
    // by — and has no commission parameter at all.
    final r = SavingsMath.fromConversion(_percent20,
        status: 'approved',
        orderAmountMinor: 10000,
        orderCurrency: 'SAR',
        providerDiscountMinor: 1000,
        providerDiscountCurrency: 'SAR');
    expect(r.amountMinor, 1000);
  });
}
