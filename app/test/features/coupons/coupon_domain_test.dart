// MALI-COUPONS (Phase C4) — snapshot decoding (§40 G–J) and on-device
// eligibility + contextual ranking (§41 A–L). Pure logic: no DB, no network.
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/observability/privacy_redactor.dart';
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

/// Decode a single-row snapshot. Row helpers stay row-shaped for readability,
/// but every assertion goes through the REAL snapshot entry point.
CouponOffer _one(Map<String, Object?> row) => CouponOffer.parseSnapshot([row]).single;

/// Asserts the whole snapshot is rejected, with the expected data-free reason.
void _expectRejected(Map<String, Object?> row, CouponSnapshotRejection reason) {
  expect(
    () => CouponOffer.parseSnapshot(<Object?>[row]),
    throwsA(isA<CouponSnapshotException>()
        .having((e) => e.reason, 'reason', reason)),
  );
}

void main() {
  group('snapshot decode (§40 G–J)', () {
    test('G: a code offer decodes with its code; a link offer with its url', () {
      final code = _one(_snapshot());
      expect(code.redemptionType, CouponRedemptionType.code);
      expect(code.code, 'SAVE20');

      final link = _one(_snapshot(type: 'link', code: null, url: 'https://example.com'));
      expect(link.redemptionType, CouponRedemptionType.link);
      expect(link.code, isNull);
      expect(link.partnerUrl, 'https://example.com');
    });

    test('C4.1 §8: the validation-failure matrix each rejects the SNAPSHOT', () {
      // Redemption shape ---------------------------------------------------
      _expectRejected(_snapshot(code: null), // code without a code
          CouponSnapshotRejection.invalidRedemptionShape);
      _expectRejected(_snapshot(type: 'link', code: null), // link, no destination
          CouponSnapshotRejection.invalidRedemptionShape);
      _expectRejected(
          _snapshot(type: 'link', code: 'X', url: 'https://e.com'), // contradictory
          CouponSnapshotRejection.invalidRedemptionShape);
      _expectRejected(_snapshot(type: 'voucher'), // unknown type
          CouponSnapshotRejection.invalidRedemptionShape);

      // Non-HTTPS destinations ---------------------------------------------
      for (final bad in ['http://e.com', 'javascript:alert(1)', 'data:text/html,x']) {
        _expectRejected(_snapshot(url: bad), CouponSnapshotRejection.insecureUrl);
      }

      // Timestamps ----------------------------------------------------------
      _expectRejected(
          _snapshot(validFrom: 'nope'), CouponSnapshotRejection.invalidTimestamp);
      _expectRejected(_snapshot(validUntil: 'not-a-date'),
          CouponSnapshotRejection.invalidTimestamp);
      _expectRejected(
          _snapshot(validUntil: 12345), CouponSnapshotRejection.invalidTimestamp);

      // Country representation ---------------------------------------------
      _expectRejected(_snapshot(countries: ['ALL']), // the retired literal
          CouponSnapshotRejection.invalidCountryCodes);
      _expectRejected(_snapshot(countries: ['sa']), // wrong case
          CouponSnapshotRejection.invalidCountryCodes);
      _expectRejected(_snapshot(countries: ['SAU']), // alpha-3
          CouponSnapshotRejection.invalidCountryCodes);
      _expectRejected(_snapshot(countries: [42]), // wrong type
          CouponSnapshotRejection.invalidCountryCodes);

      // Category structure --------------------------------------------------
      _expectRejected(
          _snapshot(category: null), CouponSnapshotRejection.invalidCategory);
      _expectRejected(_snapshot(category: 'food'), // not an object
          CouponSnapshotRejection.invalidCategory);
      _expectRejected(_snapshot(category: const {'label_ar': 'مطاعم'}), // no key
          CouponSnapshotRejection.invalidCategory);

      // Tag structure -------------------------------------------------------
      _expectRejected(_snapshot(tags: const [{'key': '', 'label_ar': 'broken'}]),
          CouponSnapshotRejection.invalidTags);
      _expectRejected(_snapshot(tags: const ['food']), // not an object
          CouponSnapshotRejection.invalidTags);

      // Identity / content --------------------------------------------------
      _expectRejected(_snapshot(id: ''), CouponSnapshotRejection.missingIdentity);
      _expectRejected(_snapshot(slug: ''), CouponSnapshotRejection.missingIdentity);
    });

    test('C4.1: a non-object row rejects the snapshot', () {
      expect(
        () => CouponOffer.parseSnapshot(<Object?>['not-a-row']),
        throwsA(isA<CouponSnapshotException>()
            .having((e) => e.reason, 'reason', CouponSnapshotRejection.notAnObject)),
      );
    });

    test('C4.1: ONE malformed row rejects the WHOLE snapshot (no partial accept)',
        () {
      final items = <Object?>[
        _snapshot(id: 'd', slug: 'd'),
        _snapshot(id: 'e', slug: 'e', code: null), // malformed
        _snapshot(id: 'f', slug: 'f'),
      ];
      expect(() => CouponOffer.parseSnapshot(items),
          throwsA(isA<CouponSnapshotException>()));
      // …and nothing partial is returned in place of the failure.
      try {
        CouponOffer.parseSnapshot(items);
        fail('snapshot must not parse');
      } on CouponSnapshotException catch (error) {
        expect(error.index, 1, reason: 'names the offending row');
        expect(error.identifier, 'e', reason: 'slug is a safe static diagnostic');
      }
    });

    test('C4.1: the rejection carries data-free diagnostics only', () {
      const error = CouponSnapshotException(
        CouponSnapshotRejection.insecureUrl,
        index: 3,
        identifier: 'partner-offer',
      );
      expect(error.toString(),
          'CouponSnapshotException(insecure_url at row 3, partner-offer)');
      // Every reason is a stable snake_case token — never server content…
      for (final reason in CouponSnapshotRejection.values) {
        expect(RegExp(r'^[a-z][a-z_]*$').hasMatch(reason.wireName), isTrue,
            reason: reason.name);
        // …and short enough to survive PrivacyRedactor, which collapses any
        // 24+ char identifier-shaped run to '[id]'. A longer token would be
        // erased on its way to the log and stop being diagnosable.
        expect(reason.wireName.length, lessThan(24), reason: reason.name);
        expect(PrivacyRedactor.redactText(reason.wireName), reason.wireName,
            reason: '${reason.name} must survive redaction verbatim');
      }
    });

    test('C4.1: an empty snapshot is VALID (distinct from a malformed one)', () {
      expect(CouponOffer.parseSnapshot(const <Object?>[]), isEmpty);
    });

    test('H: category labels and ordered tags map through unchanged', () {
      final offer = _one(_snapshot(tags: const [
        {'key': 'food', 'label_ar': 'مطاعم', 'label_en': 'Food'},
        {'key': 'delivery', 'label_ar': 'توصيل'},
      ]));
      expect(offer.category.key, 'food');
      expect(offer.category.label(), 'مطاعم');
      expect(offer.category.label(preferEnglish: true), 'Food');
      // Server order is preserved verbatim (the client never re-sorts).
      expect(offer.tags.map((t) => t.key).toList(), ['food', 'delivery']);
      expect(offer.tags.first.label(preferEnglish: true), 'Food');
      // No English label -> Arabic fallback, never the persistence key.
      expect(offer.tags[1].label(preferEnglish: true), 'توصيل');
    });

    test('I/J: [] means global; a valid allowlist maps through', () {
      expect(_one(_snapshot()).countryCodes, isEmpty);
      expect(_one(_snapshot(countries: ['SA', 'AE'])).countryCodes, ['SA', 'AE']);
    });

    test('spend hints decode as opaque strings (no validation, no FK)', () {
      final offer = _one(_snapshot(hints: ['restaurants', 'legacy_removed_key']));
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
