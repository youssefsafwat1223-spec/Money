// MALI-COUPONS (Phase C4) — snapshot decoding (§40 G–J) and on-device
// eligibility + contextual ranking (§41 A–L). Pure logic: no DB, no network.
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/features/coupons/coupon_models.dart';
import 'package:money_companion/features/coupons/coupon_ranking.dart';

final DateTime _now = DateTime.utc(2026, 8, 15, 12);

Map<String, Object?> _snapshot({
  String id = 'c1',
  String slug = 'partner-offer',
  String type = 'code',
  Object? code = 'SAVE20',
  Object? url,
  List<Object?> countries = const <Object?>[],
  List<Object?> tags = const <Object?>[],
  List<Object?> hints = const <Object?>[],
  Object? category = const {'key': 'food', 'label_ar': 'مطاعم', 'label_en': 'Food'},
  String validFrom = '2026-08-01T00:00:00.000Z',
  Object? validUntil,
}) =>
    {
      'id': id,
      'slug': slug,
      'partner_name': 'Partner',
      'title_ar': 'عنوان',
      'description_ar': 'وصف',
      'redemption_type': type,
      'code': code,
      'partner_url': url,
      'display_category': category,
      'tags': tags,
      'spend_hint_category_keys': hints,
      'country_codes': countries,
      'accent_hex': '#2563EB',
      'featured': false,
      'priority': 0,
      'valid_from': validFrom,
      'valid_until': validUntil,
    };

CouponOffer _offer({
  String id = 'c1',
  String slug = 's1',
  bool featured = false,
  int priority = 0,
  DateTime? validFrom,
  DateTime? validUntil,
  List<String> countries = const <String>[],
  List<String> hints = const <String>[],
}) =>
    CouponOffer(
      id: id,
      slug: slug,
      partnerName: 'Partner',
      titleAr: 'عنوان',
      descriptionAr: 'وصف',
      redemptionType: CouponRedemptionType.code,
      code: 'CODE',
      category: const CouponCategory(key: 'food', labelAr: 'مطاعم'),
      validFrom: validFrom ?? _now.subtract(const Duration(days: 1)),
      validUntil: validUntil,
      featured: featured,
      priority: priority,
      countryCodes: countries,
      spendHintCategoryKeys: hints,
    );

void main() {
  group('snapshot decode (§40 G–J)', () {
    test('G: a code offer decodes with its code; a link offer with its url', () {
      final code = CouponOffer.tryParseSnapshot(_snapshot())!;
      expect(code.redemptionType, CouponRedemptionType.code);
      expect(code.code, 'SAVE20');

      final link = CouponOffer.tryParseSnapshot(
        _snapshot(type: 'link', code: null, url: 'https://example.com'),
      )!;
      expect(link.redemptionType, CouponRedemptionType.link);
      expect(link.code, isNull);
      expect(link.partnerUrl, 'https://example.com');
    });

    test('G: contradictory or unsafe rows are dropped, never rendered broken', () {
      // code without a code
      expect(CouponOffer.tryParseSnapshot(_snapshot(code: null)), isNull);
      // link without a destination
      expect(
          CouponOffer.tryParseSnapshot(_snapshot(type: 'link', code: null)), isNull);
      // link carrying a contradictory code
      expect(
        CouponOffer.tryParseSnapshot(
            _snapshot(type: 'link', code: 'X', url: 'https://e.com')),
        isNull,
      );
      // non-https destinations
      for (final bad in ['http://e.com', 'javascript:alert(1)', 'data:text/html,x']) {
        expect(CouponOffer.tryParseSnapshot(_snapshot(url: bad)), isNull, reason: bad);
      }
      // unknown redemption type / missing category / bad dates
      expect(CouponOffer.tryParseSnapshot(_snapshot(type: 'voucher')), isNull);
      expect(CouponOffer.tryParseSnapshot(_snapshot(category: null)), isNull);
      expect(CouponOffer.tryParseSnapshot(_snapshot(validFrom: 'nope')), isNull);
    });

    test('H: category labels and ordered tags map through unchanged', () {
      final offer = CouponOffer.tryParseSnapshot(_snapshot(tags: [
        {'key': 'food', 'label_ar': 'مطاعم', 'label_en': 'Food'},
        {'key': 'delivery', 'label_ar': 'توصيل'},
        {'key': '', 'label_ar': 'broken'}, // malformed -> dropped
      ]))!;
      expect(offer.category.key, 'food');
      expect(offer.category.label(), 'مطاعم');
      expect(offer.category.label(preferEnglish: true), 'Food');
      // Server order is preserved verbatim (the client never re-sorts).
      expect(offer.tags.map((t) => t.key).toList(), ['food', 'delivery']);
      expect(offer.tags.first.label(preferEnglish: true), 'Food');
      // No English label -> Arabic fallback, never the persistence key.
      expect(offer.tags[1].label(preferEnglish: true), 'توصيل');
    });

    test('I/J: [] means global; a legacy "ALL" value invalidates the row', () {
      expect(CouponOffer.tryParseSnapshot(_snapshot())!.countryCodes, isEmpty);
      expect(
        CouponOffer.tryParseSnapshot(_snapshot(countries: ['SA', 'AE']))!.countryCodes,
        ['SA', 'AE'],
      );
      expect(CouponOffer.tryParseSnapshot(_snapshot(countries: ['ALL'])), isNull);
      expect(CouponOffer.tryParseSnapshot(_snapshot(countries: ['sa'])), isNull);
    });

    test('spend hints decode as opaque strings (no validation, no FK)', () {
      final offer = CouponOffer.tryParseSnapshot(
          _snapshot(hints: ['restaurants', 'legacy_removed_key']))!;
      expect(offer.spendHintCategoryKeys, ['restaurants', 'legacy_removed_key']);
    });
  });

  group('time eligibility (§41 A–D)', () {
    test('A: before valid_from is hidden', () {
      final offer = _offer(validFrom: _now.add(const Duration(hours: 1)));
      expect(offer.isLiveAt(_now), isFalse);
    });

    test('B: exactly at valid_from is visible (INCLUSIVE)', () {
      expect(_offer(validFrom: _now).isLiveAt(_now), isTrue);
    });

    test('C: before expiry is visible', () {
      final offer = _offer(validUntil: _now.add(const Duration(minutes: 1)));
      expect(offer.isLiveAt(_now), isTrue);
    });

    test('D: at/after valid_until is hidden (EXCLUSIVE)', () {
      expect(_offer(validUntil: _now).isLiveAt(_now), isFalse);
      expect(
        _offer(validUntil: _now.subtract(const Duration(seconds: 1))).isLiveAt(_now),
        isFalse,
      );
    });

    test('open-ended offers never expire', () {
      expect(_offer(validUntil: null).isLiveAt(_now), isTrue);
    });
  });

  group('country eligibility (§41 E–G)', () {
    test('E: an empty allowlist is globally available, even without a country', () {
      expect(_offer().isAvailableIn('SA'), isTrue);
      expect(_offer().isAvailableIn(null), isTrue);
    });

    test('F: a scoped offer is visible in a matching country', () {
      expect(_offer(countries: ['SA', 'AE']).isAvailableIn('sa'.toUpperCase()), isTrue);
    });

    test('G: scoped offers are hidden for mismatched or unknown countries', () {
      expect(_offer(countries: ['SA']).isAvailableIn('EG'), isFalse);
      // Conservative: unknown country sees ONLY global offers.
      expect(_offer(countries: ['SA']).isAvailableIn(null), isFalse);
      expect(_offer(countries: ['SA']).isAvailableIn(''), isFalse);
    });
  });

  group('ranking (§41 H–L)', () {
    test('H: featured offers rank first', () {
      final ranked = rankCoupons(
        [_offer(id: 'plain', priority: 99), _offer(id: 'star', featured: true)],
        now: _now,
        countryCode: 'SA',
      );
      expect(ranked.first.id, 'star');
    });

    test('I: a local spend-category match boosts an offer above priority', () {
      final ranked = rankCoupons(
        [
          _offer(id: 'high-priority', priority: 50),
          _offer(id: 'matches-spend', priority: 0, hints: ['restaurants']),
        ],
        now: _now,
        countryCode: 'SA',
        topSpendCategoryKeys: const ['restaurants', 'groceries'],
      );
      expect(ranked.first.id, 'matches-spend');
      // The strongest category outranks a weaker one.
      expect(
        couponHintBoost(_offer(hints: ['restaurants']), const ['restaurants', 'groceries']),
        2,
      );
      expect(
        couponHintBoost(_offer(hints: ['groceries']), const ['restaurants', 'groceries']),
        1,
      );
    });

    test('J: stale/unknown hints are ignored — never a boost, never a failure', () {
      final offer = _offer(id: 'stale', hints: ['category_that_no_longer_exists']);
      expect(couponHintBoost(offer, const ['restaurants']), 0);
      final ranked = rankCoupons([offer], now: _now, countryCode: 'SA',
          topSpendCategoryKeys: const ['restaurants']);
      expect(ranked.single.id, 'stale', reason: 'still eligible and rendered');
    });

    test('K: priority orders offers with equal featured/boost', () {
      final ranked = rankCoupons(
        [_offer(id: 'low', priority: 1), _offer(id: 'high', priority: 9)],
        now: _now,
        countryCode: 'SA',
      );
      expect(ranked.map((o) => o.id).toList(), ['high', 'low']);
    });

    test('K2: urgency — a sooner expiry outranks a later one; open-ended is last', () {
      final ranked = rankCoupons(
        [
          _offer(id: 'open'),
          _offer(id: 'later', validUntil: _now.add(const Duration(days: 9))),
          _offer(id: 'soon', validUntil: _now.add(const Duration(days: 2))),
        ],
        now: _now,
        countryCode: 'SA',
      );
      expect(ranked.map((o) => o.id).toList(), ['soon', 'later', 'open']);
    });

    test('L: identical offers tie-break deterministically and stably by id', () {
      final input = [_offer(id: 'b'), _offer(id: 'a'), _offer(id: 'c')];
      final first = rankCoupons(input, now: _now, countryCode: 'SA');
      final second = rankCoupons(first.toList(), now: _now, countryCode: 'SA');
      expect(first.map((o) => o.id).toList(), ['a', 'b', 'c']);
      expect(second.map((o) => o.id).toList(), first.map((o) => o.id).toList());
    });

    test('ranking filters ineligible offers before ordering', () {
      final ranked = rankCoupons(
        [
          _offer(id: 'expired', validUntil: _now.subtract(const Duration(days: 1))),
          _offer(id: 'scheduled', validFrom: _now.add(const Duration(days: 1))),
          _offer(id: 'wrong-country', countries: ['EG']),
          _offer(id: 'ok'),
        ],
        now: _now,
        countryCode: 'SA',
      );
      expect(ranked.map((o) => o.id).toList(), ['ok']);
    });
  });
}
