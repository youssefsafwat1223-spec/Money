// COUPONS Phase 1 — how an offer's value is put into words.
//
// The rule under test throughout: if the structured value is not complete
// enough to state precisely, say NOTHING. A value chip is the part people
// believe, so one that says less than the terms do is worse than no chip at
// all — and the entire pre-Phase-1 catalog has no structured value, so "say
// nothing" is the common path, not the edge case.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/features/coupons/coupon_models.dart';
import 'package:money_companion/features/coupons/coupon_value.dart';
import 'package:money_companion/l10n/app_localizations.dart';

CouponOffer _offer({
  String? benefitType,
  int? discountBps,
  int? fixedAmountMinor,
  int? minSpendMinor,
  int? maxSavingMinor,
  String? benefitCurrency,
  String verificationState = 'unverified',
}) =>
    CouponOffer(
      id: 'x',
      slug: 'x',
      partnerName: 'P',
      titleAr: 'عنوان',
      descriptionAr: 'وصف',
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
      verificationState: verificationState,
    );

void main() {
  late AppL10n en;
  late AppL10n ar;

  setUpAll(() async {
    en = await AppL10n.delegate.load(const Locale('en'));
    ar = await AppL10n.delegate.load(const Locale('ar'));
  });

  group('the headline says nothing unless it can be precise', () {
    test('a prose-only offer gets no chip', () {
      expect(CouponValueLabel.headline(_offer(), en), isNull);
    });

    test('"other" gets no chip — a generic label would imply a computation', () {
      expect(
        CouponValueLabel.headline(_offer(benefitType: 'other'), en),
        isNull,
      );
    });

    test('a percent with no rate gets no chip', () {
      expect(
        CouponValueLabel.headline(_offer(benefitType: 'percent'), en),
        isNull,
      );
    });

    test('a fixed amount with no currency gets no chip', () {
      // A minor-unit integer without a currency is not an amount. Rendering it
      // would put a number in front of the user in a currency the app picked.
      expect(
        CouponValueLabel.headline(
            _offer(benefitType: 'fixed_amount', fixedAmountMinor: 5000), en),
        isNull,
      );
    });

    test('free shipping needs no amount', () {
      expect(
        CouponValueLabel.headline(_offer(benefitType: 'free_shipping'), en),
        isNotNull,
      );
    });
  });

  group('percentages read naturally', () {
    String? pct(int bps) => CouponValueLabel.headline(
        _offer(benefitType: 'percent', discountBps: bps, benefitCurrency: 'SAR'),
        en);

    test('a whole percent drops the decimal', () {
      expect(pct(2000), contains('20'));
      expect(pct(2000), isNot(contains('20.0')));
    });

    test('a fractional percent keeps one place', () {
      expect(pct(1250), contains('12.5'));
    });

    test('100% is representable', () => expect(pct(10000), contains('100')));
  });

  group('the qualifier is never hidden behind a tap', () {
    test('a minimum spend is stated', () {
      // "20% off" and "20% off over 200" are different offers. Showing only the
      // first is how a user ends up feeling misled by a number we chose.
      final q = CouponValueLabel.qualifier(
        _offer(
            benefitType: 'percent',
            discountBps: 2000,
            minSpendMinor: 20000,
            benefitCurrency: 'SAR'),
        en,
      );
      expect(q, isNotNull);
      expect(q, contains('200'));
    });

    test('a cap is stated, and only for a percentage', () {
      final capped = CouponValueLabel.qualifier(
        _offer(
            benefitType: 'percent',
            discountBps: 2000,
            maxSavingMinor: 5000,
            benefitCurrency: 'SAR'),
        en,
      );
      expect(capped, contains('50'));

      // On a fixed amount a cap is redundant, and 0095's CHECK forbids storing
      // one. If a malformed row ever arrives, it must not be rendered.
      final fixed = CouponValueLabel.qualifier(
        _offer(
            benefitType: 'fixed_amount',
            fixedAmountMinor: 5000,
            maxSavingMinor: 9000,
            benefitCurrency: 'SAR'),
        en,
      );
      expect(fixed, isNull);
    });

    test('no currency means no qualifier', () {
      expect(
        CouponValueLabel.qualifier(
            _offer(benefitType: 'percent', discountBps: 2000, minSpendMinor: 100),
            en),
        isNull,
      );
    });
  });

  group('verification is always stated', () {
    test('an unverified offer says so rather than staying silent', () {
      // Silence would let an unchecked offer read like a checked one.
      expect(CouponValueLabel.verification(_offer(), en), isNotEmpty);
      expect(CouponValueLabel.isVerified(_offer()), isFalse);
    });

    test('the two verified states are distinguishable', () {
      // "We checked this" and "a provider feed said so" are different promises.
      final byUs = CouponValueLabel.verification(
          _offer(verificationState: 'admin_verified'), en);
      final byProvider = CouponValueLabel.verification(
          _offer(verificationState: 'provider_verified'), en);
      expect(byUs, isNot(byProvider));
      expect(CouponValueLabel.isVerified(_offer(verificationState: 'admin_verified')),
          isTrue);
    });

    test('an unrecognised state reads as the WEAKEST claim', () {
      final o = _offer(verificationState: 'totally_legit');
      expect(CouponValueLabel.isVerified(o), isFalse);
      expect(CouponValueLabel.verification(o, en),
          CouponValueLabel.verification(_offer(), en));
    });
  });

  test('every label is localised in both locales', () {
    // A value chip that falls back to English inside an Arabic UI is worse than
    // no chip: it reads as a system message rather than as part of the offer.
    final o = _offer(
        benefitType: 'percent',
        discountBps: 2000,
        minSpendMinor: 20000,
        benefitCurrency: 'SAR');
    expect(CouponValueLabel.headline(o, ar),
        isNot(CouponValueLabel.headline(o, en)));
    expect(CouponValueLabel.verification(o, ar),
        isNot(CouponValueLabel.verification(o, en)));
  });
}
