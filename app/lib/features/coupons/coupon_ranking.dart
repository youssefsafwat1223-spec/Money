import 'coupon_models.dart';

/// MALI-COUPONS (Phase C4) — on-device eligibility + contextual ranking.
///
/// PRIVACY CONTRACT: every input here is already on the device (the cached
/// catalog, the user's country, and locally-computed spend category keys), and
/// every output stays on the device. No spending history, category total or
/// account information is ever transmitted; the server never personalizes.
/// The only thing that reaches the server for coupons is
/// `record_coupon_event(coupon_id, event)` — see [CouponAnalyticsClient].

/// How many local spend categories participate in the contextual boost.
const int kCouponSpendHintDepth = 3;

/// How many offers the dashboard teaser shows.
const int kCouponTeaserLimit = 3;

/// Eligible offers only: the canonical live predicate (valid_from INCLUSIVE,
/// valid_until EXCLUSIVE) plus country targeting (empty list = global).
List<CouponOffer> eligibleCoupons(
  List<CouponOffer> offers, {
  required DateTime now,
  required String? countryCode,
}) {
  return offers.where((o) => o.isEligible(now, countryCode)).toList(growable: false);
}

/// The contextual boost tier for an offer: 2 for the user's strongest spend
/// category, 1 for the next ones, 0 when there is no match.
///
/// Unknown or stale hint keys simply never match — a coupon is NEVER dropped or
/// broken because its hints reference a category that no longer exists.
int couponHintBoost(CouponOffer offer, List<String> topSpendCategoryKeys) {
  if (offer.spendHintCategoryKeys.isEmpty || topSpendCategoryKeys.isEmpty) {
    return 0;
  }
  for (var i = 0; i < topSpendCategoryKeys.length; i++) {
    if (offer.spendHintCategoryKeys.contains(topSpendCategoryKeys[i])) {
      return i == 0 ? 2 : 1;
    }
  }
  return 0;
}

/// Filter to eligible offers, then order them deterministically:
///   1. featured first
///   2. contextual boost (local spend match) descending
///   3. priority descending
///   4. urgency: soonest `valid_until` first, open-ended last
///   5. id ascending — a stable tie-breaker so the order never flickers
///
/// Pure and synchronous: it takes prepared inputs and does no I/O, so it can be
/// called from a provider without touching the database on every frame.
List<CouponOffer> rankCoupons(
  List<CouponOffer> offers, {
  required DateTime now,
  required String? countryCode,
  List<String> topSpendCategoryKeys = const <String>[],
}) {
  final eligible = eligibleCoupons(offers, now: now, countryCode: countryCode).toList();
  final boost = <String, int>{
    for (final offer in eligible)
      offer.id: couponHintBoost(offer, topSpendCategoryKeys),
  };

  eligible.sort((a, b) {
    if (a.featured != b.featured) return a.featured ? -1 : 1;
    final boostDiff = (boost[b.id] ?? 0) - (boost[a.id] ?? 0);
    if (boostDiff != 0) return boostDiff;
    if (a.priority != b.priority) return b.priority.compareTo(a.priority);
    final aUntil = a.validUntil;
    final bUntil = b.validUntil;
    if (aUntil != null && bUntil != null && aUntil != bUntil) {
      return aUntil.compareTo(bUntil); // sooner expiry first
    }
    if (aUntil == null && bUntil != null) return 1; // open-ended last
    if (aUntil != null && bUntil == null) return -1;
    return a.id.compareTo(b.id);
  });
  return List<CouponOffer>.unmodifiable(eligible);
}
