import 'dart:convert';

import 'package:flutter/material.dart';

/// MALI-COUPONS (Phase C4) — the typed Coupon domain.
///
/// This replaces the hardcoded demo catalog: production content now comes from
/// `catalog-coupons` -> Drift `remote_coupons` -> this model -> UI. Decoding
/// (JSON columns, enums, colours, dates) happens HERE and in the DAO, never in
/// a widget.

/// How an offer is redeemed. The server guarantees exactly one shape per row
/// (0081 `coupons_redemption_shape`), and the client re-checks it while
/// decoding so a malformed row is dropped rather than rendered broken.
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

  /// Decode one `catalog-coupons` snapshot item. Returns null for a malformed or
  /// contradictory row (fail-safe: drop it rather than render something broken)
  /// — the same rule the Edge mapper applies server-side.
  static CouponOffer? tryParseSnapshot(Map<String, Object?> json) {
    String? str(Object? v) => v is String && v.trim().isNotEmpty ? v : null;

    final id = str(json['id']);
    final slug = str(json['slug']);
    final partner = str(json['partner_name']);
    final titleAr = str(json['title_ar']);
    final descriptionAr = str(json['description_ar']);
    final type = CouponRedemptionType.tryParse(json['redemption_type']);
    if (id == null || slug == null || partner == null) return null;
    if (titleAr == null || descriptionAr == null || type == null) return null;

    final code = str(json['code']);
    final url = str(json['partner_url']);
    if (type == CouponRedemptionType.code && code == null) return null;
    if (type == CouponRedemptionType.link && (url == null || code != null)) {
      return null;
    }
    // Only https destinations are ever accepted (defence in depth: the server
    // enforces it too).
    if (url != null && !url.startsWith('https://')) return null;

    final rawCategory = json['display_category'];
    if (rawCategory is! Map) return null;
    final categoryKey = str(rawCategory['key']);
    final categoryLabelAr = str(rawCategory['label_ar']);
    if (categoryKey == null || categoryLabelAr == null) return null;

    final validFrom = DateTime.tryParse(json['valid_from'] as String? ?? '');
    if (validFrom == null) return null;
    final rawUntil = json['valid_until'] as String?;
    final validUntil = rawUntil == null ? null : DateTime.tryParse(rawUntil);
    if (rawUntil != null && validUntil == null) return null;

    final countries = (json['country_codes'] as List?)
            ?.whereType<String>()
            .where((c) => RegExp(r'^[A-Z]{2}$').hasMatch(c))
            .toList() ??
        const <String>[];
    // A legacy/other value (e.g. the retired 'ALL' literal) makes the row
    // untrustworthy rather than silently global.
    final rawCountries = (json['country_codes'] as List?)?.length ?? 0;
    if (countries.length != rawCountries) return null;

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
