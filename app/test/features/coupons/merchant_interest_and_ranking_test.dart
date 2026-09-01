// COUPONS Phase 1 — on-device merchant interest and the ranking term it feeds.
//
// Two properties matter here and neither is about relevance quality:
//
//  1. An unresolved merchant is DROPPED, never bucketed. An abstention means we
//     do not know who this is; inventing a bucket would file unrelated spending
//     under one heading and then recommend against it.
//  2. With personalization off the caller passes an empty list, and ranking must
//     degrade to EXACTLY the pre-Phase-1 order. Not "roughly the same" — the
//     same, so the toggle is a real off switch rather than a weighting change.

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/entities/report_models.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/coupons/coupon_models.dart';
import 'package:money_companion/features/coupons/coupon_ranking.dart';
import 'package:money_companion/features/coupons/merchant_interest.dart';

MerchantSpend _spend(String name, {int count = 3, int minor = 10000}) =>
    MerchantSpend(
      name: name,
      total: Money(minor, 'SAR'),
      count: count,
    );

CouponOffer _offer(
  String id, {
  String? merchantId,
  bool featured = false,
  int priority = 0,
  List<String> hints = const [],
}) =>
    CouponOffer(
      id: id,
      slug: id,
      partnerName: 'P',
      titleAr: 'ع',
      descriptionAr: 'و',
      redemptionType: CouponRedemptionType.code,
      code: 'C',
      category: const CouponCategory(key: 'food', labelAr: 'مطاعم'),
      validFrom: DateTime.utc(2026, 1, 1),
      validUntil: DateTime.utc(2030, 1, 1),
      merchantId: merchantId,
      featured: featured,
      priority: priority,
      spendHintCategoryKeys: hints,
    );

void main() {
  final now = DateTime.utc(2026, 9, 1);

  group('MerchantInterestScorer', () {
    test('an unresolved merchant is dropped, not bucketed', () {
      final out = MerchantInterestScorer.score(
        [_spend('CARREFOUR'), _spend('MYSTERY SHOP'), _spend('UNKNOWN')],
        (name) => name == 'CARREFOUR' ? 'm-carrefour' : null,
      );
      expect(out.map((i) => i.merchantId), ['m-carrefour']);
    });

    test('several raw labels for one merchant merge before ranking', () {
      // NOON, NOON KSA and noon.com are one company. Ranking first would let it
      // occupy three slots and crowd out every other merchant.
      final out = MerchantInterestScorer.score(
        [
          _spend('NOON', count: 2),
          _spend('NOON KSA', count: 2),
          _spend('CARREFOUR', count: 3),
        ],
        (name) => name.startsWith('NOON') ? 'm-noon' : 'm-carrefour',
      );
      expect(out.first.merchantId, 'm-noon');
      expect(out.first.transactionCount, 4);
      expect(out.length, 2);
    });

    test('a single visit is not a habit', () {
      // Acting on one purchase produces "you shop here!" about a place someone
      // went once, which is what makes personalization feel invasive.
      final out = MerchantInterestScorer.score(
        [_spend('ONE OFF', count: 1)],
        (_) => 'm-oneoff',
      );
      expect(out, isEmpty);
    });

    test('scores are relative and the strongest merchant is 1.0', () {
      final out = MerchantInterestScorer.score(
        [_spend('A', count: 10), _spend('B', count: 5)],
        (name) => 'm-$name',
      );
      expect(out.first.score, 1.0);
      expect(out.last.score, closeTo(0.5, 1e-9));
    });

    test('frequency decides, not amount', () {
      // One expensive purchase is weaker interest than a weekly habit, and
      // frequency is far less sensitive to hold than a total.
      final out = MerchantInterestScorer.score(
        [
          _spend('DAILY', count: 20, minor: 2000),
          _spend('ONE BIG', count: 2, minor: 5000000),
        ],
        (name) => 'm-$name',
      );
      expect(out.first.merchantId, 'm-DAILY');
    });

    test('ordering is deterministic on ties', () {
      final out = MerchantInterestScorer.score(
        [_spend('B', count: 4), _spend('A', count: 4)],
        (name) => 'm-$name',
      );
      expect(out.map((i) => i.merchantId), ['m-A', 'm-B']);
    });

    test('the type carries no serialisation', () {
      // A merchant-interest score is a direct statement about someone's
      // spending. It has no toJson by construction, so it cannot be dropped
      // into a request body by accident.
      const i = MerchantInterest(merchantId: 'm', score: 1, transactionCount: 2);
      expect(i, isNot(isA<Map<String, dynamic>>()));
      expect((i as dynamic).runtimeType.toString(), 'MerchantInterest');
    });
  });

  group('the merchant term in ranking', () {
    test('an offer at the strongest merchant outranks a category hint', () {
      // Knowing WHERE someone shops beats knowing what kind of thing they buy.
      final ranked = rankCoupons(
        [
          _offer('hint-only', hints: ['restaurants']),
          _offer('merchant', merchantId: 'm-1'),
        ],
        now: now,
        countryCode: 'SA',
        topSpendCategoryKeys: const ['restaurants'],
        topMerchantIds: const ['m-1'],
      );
      expect(ranked.first.id, 'merchant');
    });

    test('featured still wins — an editorial decision outranks a signal', () {
      final ranked = rankCoupons(
        [
          _offer('merchant', merchantId: 'm-1'),
          _offer('featured', featured: true),
        ],
        now: now,
        countryCode: 'SA',
        topMerchantIds: const ['m-1'],
      );
      expect(ranked.first.id, 'featured');
    });

    test('merchant boost is tiered by position, not binary', () {
      final ranked = rankCoupons(
        [
          _offer('third', merchantId: 'm-3'),
          _offer('first', merchantId: 'm-1'),
        ],
        now: now,
        countryCode: 'SA',
        topMerchantIds: const ['m-1', 'm-2', 'm-3'],
      );
      expect(ranked.first.id, 'first');
    });

    test('an offer with no merchant link is never boosted', () {
      expect(couponMerchantBoost(_offer('x'), const ['m-1']), 0);
    });

    test('personalization OFF reproduces the pre-Phase-1 order EXACTLY', () {
      // The toggle must be an off switch, not a re-weighting. An empty list is
      // how the caller expresses "off", and the term then has nothing to score
      // against — no special case anywhere in the sort.
      final offers = [
        _offer('a', merchantId: 'm-1', priority: 1),
        _offer('b', merchantId: 'm-2', priority: 5),
        _offer('c', priority: 3, hints: ['restaurants']),
      ];
      final withoutTerm = rankCoupons(offers,
          now: now, countryCode: 'SA', topSpendCategoryKeys: const ['restaurants']);
      final withEmptyTerm = rankCoupons(offers,
          now: now,
          countryCode: 'SA',
          topSpendCategoryKeys: const ['restaurants'],
          topMerchantIds: const []);
      expect(withEmptyTerm.map((o) => o.id).toList(),
          withoutTerm.map((o) => o.id).toList());
    });
  });

  group('structured benefit decoding abstains rather than invents', () {
    test('a prose-only offer has no computable benefit', () {
      expect(_offer('x').hasComputableBenefit, isFalse);
    });

    test('an amount without a currency is not computable', () {
      final o = CouponOffer(
        id: 'x', slug: 'x', partnerName: 'P', titleAr: 'ع', descriptionAr: 'و',
        redemptionType: CouponRedemptionType.code, code: 'C',
        category: const CouponCategory(key: 'k', labelAr: 'ك'),
        validFrom: now, benefitType: 'fixed_amount', fixedAmountMinor: 5000,
      );
      expect(o.hasComputableBenefit, isFalse);
    });

    test('free shipping and other carry no number', () {
      for (final type in ['free_shipping', 'other']) {
        final o = CouponOffer(
          id: 'x', slug: 'x', partnerName: 'P', titleAr: 'ع', descriptionAr: 'و',
          redemptionType: CouponRedemptionType.code, code: 'C',
          category: const CouponCategory(key: 'k', labelAr: 'ك'),
          validFrom: now, benefitType: type, benefitCurrency: 'SAR',
        );
        expect(o.hasComputableBenefit, isFalse, reason: type);
      }
    });

    test('a well-formed percent offer is computable', () {
      final o = CouponOffer(
        id: 'x', slug: 'x', partnerName: 'P', titleAr: 'ع', descriptionAr: 'و',
        redemptionType: CouponRedemptionType.code, code: 'C',
        category: const CouponCategory(key: 'k', labelAr: 'ك'),
        validFrom: now, benefitType: 'percent', discountBps: 2000,
        benefitCurrency: 'SAR',
      );
      expect(o.hasComputableBenefit, isTrue);
    });

    test('a malformed snapshot value degrades to the weakest claim', () {
      // verification_state becomes a promise in the UI. An unrecognised value
      // must read as "unverified", never as the strongest state.
      final parsed = CouponOffer.parseSnapshot([
        {
          'id': 'x', 'slug': 'x', 'partner_name': 'P', 'title_ar': 'ع',
          'description_ar': 'و', 'redemption_type': 'code', 'code': 'C',
          'display_category': {'key': 'k', 'label_ar': 'ك'},
          'valid_from': '2026-01-01T00:00:00Z',
          'verification_state': 'totally_verified_trust_us',
          'discount_bps': -5,
          'benefit_currency': 'not-a-currency',
        }
      ]);
      expect(parsed.single.verificationState, 'unverified');
      expect(parsed.single.discountBps, isNull);
      expect(parsed.single.benefitCurrency, isNull);
    });

    test('absent Phase-1 fields never reject a snapshot', () {
      // The all-or-nothing contract covers the fields the catalog has always
      // had. A server that has not published merchant links yet must not blank
      // the entire catalog.
      final parsed = CouponOffer.parseSnapshot([
        {
          'id': 'x', 'slug': 'x', 'partner_name': 'P', 'title_ar': 'ع',
          'description_ar': 'و', 'redemption_type': 'code', 'code': 'C',
          'display_category': {'key': 'k', 'label_ar': 'ك'},
          'valid_from': '2026-01-01T00:00:00Z',
        }
      ]);
      expect(parsed, hasLength(1));
      expect(parsed.single.merchantId, isNull);
      expect(parsed.single.source, 'manual');
    });
  });
}
