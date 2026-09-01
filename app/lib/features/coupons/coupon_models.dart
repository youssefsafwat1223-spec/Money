import 'dart:convert';

import 'package:flutter/material.dart';

/// MALI-COUPONS (Phase C4) — the typed Coupon domain.
///
/// This replaces the hardcoded demo catalog: production content now comes from
/// `catalog-coupons` -> Drift `remote_coupons` -> this model -> UI. Decoding
/// (JSON columns, enums, colours, dates) happens HERE and in the DAO, never in
/// a widget.

/// Why a catalog snapshot was rejected.
///
/// A stable, data-free vocabulary: these values are safe to log verbatim. They
/// describe WHICH contract the row broke, never what the row contained.
///
/// Each token MUST stay under 24 characters: `PrivacyRedactor` collapses any
/// longer `[A-Za-z0-9_-]` run to `[id]`, which would erase the diagnostic on
/// its way to the log. A test locks this.
enum CouponSnapshotRejection {
  notAnObject('not_an_object'),
  missingIdentity('missing_identity'),
  missingContent('missing_content'),
  invalidRedemptionShape('invalid_redemption'),
  insecureUrl('insecure_url'),
  invalidCategory('invalid_category'),
  invalidTimestamp('invalid_timestamp'),
  invalidCountryCodes('invalid_country_codes'),
  invalidTags('invalid_tags'),
  invalidSpendHints('invalid_spend_hints');

  const CouponSnapshotRejection(this.wireName);

  final String wireName;
}

/// Raised when ANY row of a `catalog-coupons` snapshot fails validation.
///
/// The snapshot is ONE authoritative unit. A single bad row rejects the whole
/// payload, so a partially-valid catalog can never replace the last-known-good
/// cache — silently dropping rows would shrink a user's catalog while still
/// looking like a successful sync.
///
/// Carries only data-free diagnostics: the fixed [reason], the row [index], and
/// the server's static coupon identifier. Never server content, never user
/// data, never a stack trace — and it is never surfaced to the user.
class CouponSnapshotException implements Exception {
  const CouponSnapshotException(
    this.reason, {
    required this.index,
    this.identifier,
  });

  final CouponSnapshotRejection reason;

  /// Position of the offending row within the snapshot.
  final int index;

  /// The row's `slug` (preferred) or `id`, when it was readable as a plain
  /// string before validation failed. Bounded so a pathological value cannot
  /// dominate a log line.
  final String? identifier;

  @override
  String toString() => 'CouponSnapshotException(${reason.wireName} at row '
      '$index${identifier == null ? '' : ', $identifier'})';
}

/// How an offer is redeemed. The server guarantees exactly one shape per row
/// (0081 `coupons_redemption_shape`), and the client re-checks it while
/// decoding so a malformed row rejects the snapshot rather than rendering
/// something broken.
enum CouponRedemptionType {
  /// Copy a code; an optional partner link may be offered as a secondary CTA.
  code,

  /// A single destination link; carries no code.
  link;

  static CouponRedemptionType? tryParse(Object? value) => switch (value) {
        'code' => CouponRedemptionType.code,
        'link' => CouponRedemptionType.link,
        _ => null,
      };
}

/// A Coupon-owned display tag (normalized key + display labels).
@immutable
class CouponTag {
  const CouponTag({required this.key, required this.labelAr, this.labelEn});

  final String key;
  final String labelAr;
  final String? labelEn;

  /// Never renders the persistence key when a display label exists.
  String label({bool preferEnglish = false}) =>
      preferEnglish && (labelEn?.trim().isNotEmpty ?? false) ? labelEn! : labelAr;

  static CouponTag? tryParse(Object? value) {
    if (value is! Map) return null;
    final key = value['key'];
    final labelAr = value['label_ar'];
    if (key is! String || key.isEmpty) return null;
    if (labelAr is! String || labelAr.trim().isEmpty) return null;
    return CouponTag(
      key: key,
      labelAr: labelAr,
      labelEn: value['label_en'] as String?,
    );
  }

  Map<String, Object?> toJson() =>
      {'key': key, 'label_ar': labelAr, 'label_en': labelEn};

  @override
  bool operator ==(Object other) => other is CouponTag && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

/// The Coupon-OWNED display category. Deliberately independent of the app's
/// financial transaction categories: the offer taxonomy can evolve separately.
@immutable
class CouponCategory {
  const CouponCategory({required this.key, required this.labelAr, this.labelEn});

  final String key;
  final String labelAr;
  final String? labelEn;

  String label({bool preferEnglish = false}) =>
      preferEnglish && (labelEn?.trim().isNotEmpty ?? false) ? labelEn! : labelAr;

  @override
  bool operator ==(Object other) => other is CouponCategory && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

@immutable
class CouponOffer {
  const CouponOffer({
    required this.id,
    required this.slug,
    required this.partnerName,
    required this.titleAr,
    required this.descriptionAr,
    required this.redemptionType,
    required this.category,
    required this.validFrom,
    this.titleEn,
    this.descriptionEn,
    this.code,
    this.partnerUrl,
    this.tags = const <CouponTag>[],
    this.spendHintCategoryKeys = const <String>[],
    this.countryCodes = const <String>[],
    this.accentHex,
    this.imageUrl,
    this.featured = false,
    this.priority = 0,
    this.validUntil,
    this.termsAr,
    this.merchantId,
    this.merchantSlug,
    this.merchantNameAr,
    this.merchantNameEn,
    this.benefitType,
    this.discountBps,
    this.fixedAmountMinor,
    this.minSpendMinor,
    this.maxSavingMinor,
    this.benefitCurrency,
    this.source = 'manual',
    this.verificationState = 'unverified',
  });

  final String id;
  final String slug;
  final String partnerName;
  final String titleAr;
  final String? titleEn;
  final String descriptionAr;
  final String? descriptionEn;

  final CouponRedemptionType redemptionType;

  /// Present only for [CouponRedemptionType.code].
  final String? code;

  /// Required for [CouponRedemptionType.link]; optional secondary CTA for code.
  final String? partnerUrl;

  final CouponCategory category;

  /// Server-ordered (sort_order, key) — the client never re-sorts them.
  final List<CouponTag> tags;

  /// Optional financial-category keys used ONLY by on-device ranking. Unknown
  /// or stale keys simply produce no boost; they never invalidate the offer.
  final List<String> spendHintCategoryKeys;

  /// EMPTY means globally available. Otherwise an ISO-3166-1 alpha-2 allowlist.
  final List<String> countryCodes;

  final String? accentHex;
  final String? imageUrl;
  final bool featured;
  final int priority;
  final DateTime validFrom;
  final DateTime? validUntil;
  final String? termsAr;

  // ── COUPONS Phase 1 — merchant link and structured value ────────────────
  //
  // ALL NULLABLE, and deliberately outside the all-or-nothing snapshot
  // contract: a cache written by an older build, or a server that has not
  // published these yet, must keep working rather than reject the snapshot.
  // Absent simply means "no structured value", and every consumer must handle
  // that by abstaining rather than by inferring one.

  /// The canonical merchant this offer belongs to, when it has been linked.
  /// `partnerName` remains the display fallback.
  final String? merchantId;
  final String? merchantSlug;
  final String? merchantNameAr;
  final String? merchantNameEn;

  /// `percent` | `fixed_amount` | `free_shipping` | `other`. Null means the
  /// offer's value is prose only — which is the entire pre-Phase-1 catalog.
  final String? benefitType;

  /// Basis points: 1250 is 12.5%. An integer so nothing rounds on the way to a
  /// savings figure.
  final int? discountBps;
  final int? fixedAmountMinor;
  final int? minSpendMinor;

  /// The cap on a percentage offer. Without it an estimate is unbounded and
  /// wrong on exactly the large baskets a user would notice.
  final int? maxSavingMinor;

  /// Required whenever any minor amount is present — a minor-unit integer with
  /// no currency is not an amount.
  final String? benefitCurrency;

  final String source;

  /// `unverified` | `admin_verified` | `provider_verified`. Surfaced to the
  /// user: "we checked this" and "a feed said so" are different promises.
  final String verificationState;

  /// True only when the structured fields are complete enough to compute with.
  /// The savings layer must consult this rather than testing fields ad hoc, so
  /// there is one definition of "we can put a number on this".
  bool get hasComputableBenefit {
    switch (benefitType) {
      case 'percent':
        return discountBps != null && discountBps! > 0 && benefitCurrency != null;
      case 'fixed_amount':
        return fixedAmountMinor != null &&
            fixedAmountMinor! > 0 &&
            benefitCurrency != null;
      default:
        // free_shipping and other carry no computable amount, and a null type
        // is a prose-only offer. Both must produce no number at all.
        return false;
    }
  }

  String? merchantName({bool preferEnglish = false}) =>
      preferEnglish && (merchantNameEn?.trim().isNotEmpty ?? false)
          ? merchantNameEn
          : merchantNameAr;

  String title({bool preferEnglish = false}) =>
      preferEnglish && (titleEn?.trim().isNotEmpty ?? false) ? titleEn! : titleAr;

  String description({bool preferEnglish = false}) =>
      preferEnglish && (descriptionEn?.trim().isNotEmpty ?? false)
          ? descriptionEn!
          : descriptionAr;

  /// Decorative accent. Used as trim/tint only — never as a text background,
  /// because a partner-supplied colour cannot be contrast-checked.
  Color? get accentColor {
    final hex = accentHex;
    if (hex == null || !RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(hex)) return null;
    return Color(int.parse('FF${hex.substring(1)}', radix: 16));
  }

  /// THE canonical live predicate, identical to 0081 `public.coupon_is_live`
  /// and to the `catalog-coupons` query: `valid_from` INCLUSIVE, `valid_until`
  /// EXCLUSIVE. Re-checked on device so a cached offer expires without waiting
  /// for another sync.
  bool isLiveAt(DateTime now) =>
      !validFrom.isAfter(now) && (validUntil == null || validUntil!.isAfter(now));

  /// Country eligibility: an empty allowlist means global. When the user's
  /// country is unknown, ONLY global offers are eligible (conservative).
  bool isAvailableIn(String? countryCode) {
    if (countryCodes.isEmpty) return true;
    final country = countryCode?.trim().toUpperCase();
    if (country == null || country.isEmpty) return false;
    return countryCodes.contains(country);
  }

  bool isEligible(DateTime now, String? countryCode) =>
      isLiveAt(now) && isAvailableIn(countryCode);

  /// True within the last week of the validity window (drives the urgency pill).
  bool expiresSoon(DateTime now) {
    final until = validUntil;
    if (until == null || !isLiveAt(now)) return false;
    return until.difference(now).inDays <= 7;
  }

  /// Decode an ENTIRE `catalog-coupons` snapshot — all-or-nothing.
  ///
  /// Returns the fully typed catalog, or throws [CouponSnapshotException] on the
  /// first invalid row, in which case the caller MUST keep its previous cache.
  /// There is deliberately no "drop the bad rows" mode: a partially-valid
  /// snapshot would replace a good catalog with a smaller one and still report
  /// success. An empty [items] list is a legitimate snapshot (an empty
  /// catalog) — that is the only way this returns an empty result.
  ///
  /// Validation runs to completion BEFORE any caller touches the database, so
  /// the destructive replace can never begin against a snapshot that turns out
  /// to be invalid halfway through.
  static List<CouponOffer> parseSnapshot(List<Object?> items) {
    final offers = <CouponOffer>[];
    for (var index = 0; index < items.length; index++) {
      offers.add(_parseRow(items[index], index));
    }
    return List<CouponOffer>.unmodifiable(offers);
  }

  /// Decode and validate one snapshot row, or throw. Every check here is a
  /// contract the server also enforces (0081) — this is defence in depth, not a
  /// substitute for it.
  /// Reads an integer that must be strictly positive to mean anything. A zero
  /// or negative discount, cap or amount is data corruption, and treating it as
  /// a real value would put "you saved 0" in front of a user.
  static int? _positiveInt(Object? v) {
    final n = v is num ? v.toInt() : (v is String ? int.tryParse(v) : null);
    return (n != null && n > 0) ? n : null;
  }

  static int? _nonNegativeInt(Object? v) {
    final n = v is num ? v.toInt() : (v is String ? int.tryParse(v) : null);
    return (n != null && n >= 0) ? n : null;
  }

  /// Only a well-formed ISO code is accepted. Anything else becomes null, which
  /// makes [CouponOffer.hasComputableBenefit] false and the savings layer
  /// abstain — the correct outcome for an amount whose currency we cannot name.
  static String? _currencyCode(Object? v) {
    if (v is! String) return null;
    final code = v.trim().toUpperCase();
    return RegExp(r'^[A-Z]{3}$').hasMatch(code) ? code : null;
  }

  /// An unrecognised verification state degrades to `unverified` rather than
  /// being shown verbatim: this string becomes a claim in the UI, and an
  /// unknown claim must read as the weakest one, never the strongest.
  static String _verificationState(Object? v) {
    const known = {'unverified', 'admin_verified', 'provider_verified'};
    final s = v is String ? v.trim() : '';
    return known.contains(s) ? s : 'unverified';
  }

  static CouponOffer _parseRow(Object? raw, int index) {
    if (raw is! Map) {
      throw CouponSnapshotException(
        CouponSnapshotRejection.notAnObject,
        index: index,
      );
    }
    final json = raw.map((k, v) => MapEntry(k.toString(), v));

    String? str(Object? v) => v is String && v.trim().isNotEmpty ? v : null;

    // Resolved first so every rejection below can name the offending row.
    final id = str(json['id']);
    final slug = str(json['slug']);
    final label = slug ?? id;
    final identifier =
        label == null ? null : (label.length <= 64 ? label : label.substring(0, 64));

    Never reject(CouponSnapshotRejection reason) => throw CouponSnapshotException(
          reason,
          index: index,
          identifier: identifier,
        );

    final partner = str(json['partner_name']);
    if (id == null || slug == null || partner == null) {
      reject(CouponSnapshotRejection.missingIdentity);
    }

    final titleAr = str(json['title_ar']);
    final descriptionAr = str(json['description_ar']);
    if (titleAr == null || descriptionAr == null) {
      reject(CouponSnapshotRejection.missingContent);
    }

    final type = CouponRedemptionType.tryParse(json['redemption_type']);
    final code = str(json['code']);
    final url = str(json['partner_url']);
    if (type == null) reject(CouponSnapshotRejection.invalidRedemptionShape);
    if (type == CouponRedemptionType.code && code == null) {
      reject(CouponSnapshotRejection.invalidRedemptionShape);
    }
    if (type == CouponRedemptionType.link && (url == null || code != null)) {
      reject(CouponSnapshotRejection.invalidRedemptionShape);
    }
    // Only https destinations are ever accepted (defence in depth: the server
    // enforces it too).
    if (url != null && !url.startsWith('https://')) {
      reject(CouponSnapshotRejection.insecureUrl);
    }

    final rawCategory = json['display_category'];
    if (rawCategory is! Map) reject(CouponSnapshotRejection.invalidCategory);
    final categoryKey = str(rawCategory['key']);
    final categoryLabelAr = str(rawCategory['label_ar']);
    if (categoryKey == null || categoryLabelAr == null) {
      reject(CouponSnapshotRejection.invalidCategory);
    }

    final rawFrom = json['valid_from'];
    final validFrom = rawFrom is String ? DateTime.tryParse(rawFrom) : null;
    if (validFrom == null) reject(CouponSnapshotRejection.invalidTimestamp);
    final rawUntil = json['valid_until'];
    if (rawUntil != null && rawUntil is! String) {
      reject(CouponSnapshotRejection.invalidTimestamp);
    }
    final validUntil =
        rawUntil == null ? null : DateTime.tryParse(rawUntil as String);
    if (rawUntil != null && validUntil == null) {
      reject(CouponSnapshotRejection.invalidTimestamp);
    }

    final rawCountries = json['country_codes'];
    if (rawCountries != null && rawCountries is! List) {
      reject(CouponSnapshotRejection.invalidCountryCodes);
    }
    final countryList = rawCountries as List?;
    final countries = countryList
            ?.whereType<String>()
            .where((c) => RegExp(r'^[A-Z]{2}$').hasMatch(c))
            .toList() ??
        const <String>[];
    // A legacy/other value (e.g. the retired 'ALL' literal) makes the row
    // untrustworthy rather than silently global.
    if (countries.length != (countryList?.length ?? 0)) {
      reject(CouponSnapshotRejection.invalidCountryCodes);
    }

    final rawTags = json['tags'];
    if (rawTags != null && rawTags is! List) {
      reject(CouponSnapshotRejection.invalidTags);
    }
    final tags = <CouponTag>[];
    for (final rawTag in (rawTags as List?) ?? const <Object?>[]) {
      final tag = CouponTag.tryParse(rawTag);
      // A malformed tag is a malformed ROW: dropping it would quietly change
      // what the offer is filed under.
      if (tag == null) reject(CouponSnapshotRejection.invalidTags);
      tags.add(tag);
    }

    final rawHints = json['spend_hint_category_keys'];
    if (rawHints != null && rawHints is! List) {
      reject(CouponSnapshotRejection.invalidSpendHints);
    }
    final hintList = rawHints as List?;
    final hints = hintList?.whereType<String>().toList() ?? const <String>[];
    if (hints.length != (hintList?.length ?? 0)) {
      reject(CouponSnapshotRejection.invalidSpendHints);
    }

    return CouponOffer(
      id: id,
      slug: slug,
      partnerName: partner,
      titleAr: titleAr,
      titleEn: str(json['title_en']),
      descriptionAr: descriptionAr,
      descriptionEn: str(json['description_en']),
      redemptionType: type,
      code: code,
      partnerUrl: url,
      category: CouponCategory(
        key: categoryKey,
        labelAr: categoryLabelAr,
        labelEn: str(rawCategory['label_en']),
      ),
      tags: (json['tags'] as List?)
              ?.map(CouponTag.tryParse)
              .whereType<CouponTag>()
              .toList() ??
          const <CouponTag>[],
      spendHintCategoryKeys:
          (json['spend_hint_category_keys'] as List?)?.whereType<String>().toList() ??
              const <String>[],
      countryCodes: countries,
      // ── Phase 1 fields — TOLERANT, never a rejection reason ──────────────
      //
      // The snapshot contract is all-or-nothing on purpose: one malformed row
      // must not silently drop an offer while the rest render. But that
      // contract applies to the fields the catalog has always had. A server
      // that has not published merchant links yet, or a nullable value that is
      // simply absent, must not blank the entire catalog — so these decode to
      // null and every consumer abstains on null.
      merchantId: str(json['merchant_id']),
      merchantSlug: str(json['merchant_slug']),
      merchantNameAr: str(json['merchant_name_ar']),
      merchantNameEn: str(json['merchant_name_en']),
      benefitType: str(json['benefit_type']),
      discountBps: _positiveInt(json['discount_bps']),
      fixedAmountMinor: _positiveInt(json['fixed_amount_minor']),
      // A minimum spend of zero is meaningful ("no minimum"), so it uses the
      // non-negative reader rather than the positive one.
      minSpendMinor: _nonNegativeInt(json['min_spend_minor']),
      maxSavingMinor: _positiveInt(json['max_saving_minor']),
      benefitCurrency: _currencyCode(json['benefit_currency']),
      source: str(json['source']) ?? 'manual',
      verificationState: _verificationState(json['verification_state']),
      accentHex: str(json['accent_hex']),
      imageUrl: str(json['image_url']),
      featured: json['featured'] == true,
      priority: (json['priority'] as num?)?.toInt() ?? 0,
      validFrom: validFrom,
      validUntil: validUntil,
      termsAr: str(json['terms_ar']),
    );
  }

  /// Encode the embedded collections for the Drift cache (deterministic order).
  String get tagsJson => jsonEncode(tags.map((t) => t.toJson()).toList());
  String get spendHintsJson => jsonEncode(spendHintCategoryKeys);
  String get countryCodesJson => jsonEncode(countryCodes);
}
