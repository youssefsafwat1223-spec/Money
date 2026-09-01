import 'coupon_models.dart';

/// MALI-COUPONS (Phase C4) — on-device eligibility + contextual ranking.
///
/// PRIVACY CONTRACT: every input here is already on the device (the cached
/// catalog, the user's country, and locally-computed spend category keys), and
/// every output stays on the device. No spending history, category total or
/// account information is ever transmitted; the server never personalizes.
/// The only thing that reaches the server for coupons is
/// `record_coupon_event(coupon_id, event)` — see [CouponAnalyticsClient].
///
/// Phase 1 adds a merchant term to the same contract. `topMerchantIds` are
/// CANONICAL CATALOG ids resolved on device from the local ledger; the list is
/// an input to a pure sort and is never sent anywhere. A caller that has
/// personalization off passes an empty list, so the term contributes nothing —
/// the toggle is honoured in ONE place rather than being re-checked here.

/// How many local spend categories participate in the contextual boost.
const int kCouponSpendHintDepth = 3;

/// How many merchants participate in the merchant boost.
///
/// Deliberately small. The point is "an offer at a place you actually shop",
/// not a ranked model of someone's life, and a long tail of weak signals would
/// let a barely-visited merchant outrank a genuinely good offer.
const int kCouponMerchantDepth = 5;

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

/// The merchant boost tier for an offer: 3 when the offer is for the user's
/// strongest merchant, 2 or 1 for the next ones, 0 with no match.
///
/// Ranks ABOVE the category hint deliberately. "20% off at the supermarket you
/// go to every week" is a materially better recommendation than "20% off
/// something in groceries", and the merchant signal is the only one precise
/// enough to justify saying so.
///
/// Returns 0 for every offer when [interests] is empty — which is what happens
/// when the user has personalization off. That is the whole mechanism: the term
/// is not skipped or specially-cased, it simply has nothing to score against, so
/// ranking degrades to exactly the pre-Phase-1 order.
int couponMerchantBoost(CouponOffer offer, List<String> topMerchantIds) {
  final merchantId = offer.merchantId;
  if (merchantId == null || topMerchantIds.isEmpty) return 0;
  final index = topMerchantIds.indexOf(merchantId);
  if (index < 0) return 0;
  if (index == 0) return 3;
  return index <= 2 ? 2 : 1;
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
  /// Canonical merchant ids, strongest first. EMPTY when the user has merchant
  /// personalization off — the caller passes nothing rather than the ranking
  /// deciding, so there is exactly one place the toggle is honoured.
  List<String> topMerchantIds = const <String>[],
}) {
  final eligible = eligibleCoupons(offers, now: now, countryCode: countryCode).toList();
  final boost = <String, int>{
    for (final offer in eligible)
      offer.id: couponHintBoost(offer, topSpendCategoryKeys),
  };
  final merchantBoost = <String, int>{
    for (final offer in eligible)
      offer.id: couponMerchantBoost(offer, topMerchantIds),
  };

  eligible.sort((a, b) {
    if (a.featured != b.featured) return a.featured ? -1 : 1;
    // Merchant match outranks the category hint: knowing WHERE someone shops is
    // a stronger signal than knowing what kind of thing they buy.
    final merchantDiff = (merchantBoost[b.id] ?? 0) - (merchantBoost[a.id] ?? 0);
    if (merchantDiff != 0) return merchantDiff;
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
