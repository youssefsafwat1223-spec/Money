import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../data/catalog/catalog_daos.dart';
import '../common/category_catalog.dart';
import 'coupon_analytics.dart';
import 'coupon_models.dart';
import 'coupon_ranking.dart';
import 'merchant_interest.dart';
import 'merchant_lookup_pipeline.dart';

/// MALI-COUPONS (Phase C4) — the Coupons read path.
///
/// Production content comes exclusively from the server catalog:
///   catalog-coupons -> CatalogSyncService -> Drift `remote_coupons` -> here.
/// There is NO hardcoded fallback catalog: when the cache is empty the UI shows
/// an empty state rather than inventing offers. (Fixtures live only in tests.)

/// The whole user-facing feature is gated by the existing remote flag, which
/// is seeded OFF and fails closed.
final couponsEnabledProvider = Provider<bool>((ref) {
  return featureFlags.getBool('enable_coupons');
});

/// The cached catalog, exactly as synced (no eligibility applied yet).
final cachedCouponsProvider = FutureProvider<List<CouponOffer>>((ref) async {
  // Catalog writes bump the generic DB revision, so the cache refreshes after a
  // sync without any manual invalidation.
  ref.watch(dbRevisionProvider);
  return RemoteCouponsDao(ref.watch(appDatabaseProvider)).getAll();
});

/// The user's country for eligibility. Null when it cannot be determined, in
/// which case ONLY globally-available offers are shown (conservative default).
final couponCountryProvider = FutureProvider<String?>((ref) async {
  ref.watch(dbRevisionProvider);
  final settings = await ref.watch(loadUserSettingsUseCaseProvider).call();
  final country = settings.country.trim().toUpperCase();
  return country.isEmpty ? null : country;
});

/// The user's strongest local spending categories (stable category KEYS) over
/// the last 30 days, used only to order offers ON DEVICE.
///
/// This is a memoized [FutureProvider] backed by the existing SQL aggregate —
/// no transaction is ever scanned inside a widget build, and nothing derived
/// from it ever leaves the device.
final couponSpendHintsProvider = FutureProvider<List<String>>((ref) async {
  // Recomputes only when transactions/categories actually change.
  ref.watch(scopedRevisionProvider(kReportsRevisionTables));
  final currency = await ref.watch(baseCurrencyProvider.future);
  final catalog = await ref.watch(categoryCatalogProvider.future);
  final now = DateTime.now();
  final breakdown = await ref.watch(transactionRepositoryProvider).categoryBreakdown(
        from: now.subtract(const Duration(days: 30)),
        to: now,
        currency: currency,
      );
  // `categoryBreakdown` already returns rows ordered by total DESC.
  return breakdown
      .map((row) => catalog.byId(row.categoryId)?.key)
      .whereType<String>()
      .take(kCouponSpendHintDepth)
      .toList(growable: false);
});

// ── COUPONS Phase 1 — merchant awareness ────────────────────────────────────
//
// Everything below runs on the device, from the device's own ledger, and
// produces values that are only ever inputs to a local sort. No merchant id, no
// interest score and no spend aggregate is transmitted anywhere; the coupon
// feature's ONLY outbound call remains record_coupon_event(coupon_id, event).

/// The merchant catalog and pages, behind their own kill switch.
///
/// Independent of `enable_coupons` on purpose: the generic catalog must keep
/// working if merchant awareness has to be switched off, and one flag that
/// disables everything is not a kill switch, it is an outage.
final merchantOffersEnabledProvider = Provider<bool>((ref) {
  return featureFlags.getBool('enable_offers_merchants');
});

/// Whether the USER has turned on merchant personalization. Local only, off by
/// default, and distinct from the flag above: the flag decides whether the
/// capability exists, this decides whether the user wants it.
final merchantPersonalizationEnabledProvider = FutureProvider<bool>((ref) async {
  ref.watch(dbRevisionProvider);
  if (!ref.watch(merchantOffersEnabledProvider)) return false;
  final settings = await ref.watch(loadUserSettingsUseCaseProvider).call();
  return settings.merchantPersonalizationEnabled;
});

/// The resolver, bound to the cached alias table.
final merchantLookupPipelineProvider = Provider<MerchantLookupPipeline>((ref) {
  return MerchantLookupPipeline(
    RemoteMerchantAliasesDao(ref.watch(appDatabaseProvider)),
  );
});

/// The user's strongest CANONICAL merchants over the last 90 days.
///
/// Returns EMPTY whenever the capability flag is off or the user has not opted
/// in — the single place the toggle is honoured. Everything downstream just
/// receives a list, so no consumer can forget to check.
///
/// A 90-day window rather than the category hints' 30: merchant habits are
/// slower-moving than category mix, and a short window makes the strongest
/// merchant flip on a single quiet month.
final topMerchantIdsProvider = FutureProvider<List<String>>((ref) async {
  if (!await ref.watch(merchantPersonalizationEnabledProvider.future)) {
    return const <String>[];
  }
  ref.watch(scopedRevisionProvider(kReportsRevisionTables));
  final currency = await ref.watch(baseCurrencyProvider.future);
  final now = DateTime.now();
  final spend = await ref.watch(transactionRepositoryProvider).merchantBreakdown(
        from: now.subtract(const Duration(days: 90)),
        to: now,
        currency: currency,
        // Resolve a wider slice than we will use: several raw labels can fold
        // into one merchant, so taking the top 5 BEFORE resolution would hide a
        // merchant that only wins once its labels are merged.
        limit: 40,
      );
  if (spend.isEmpty) return const <String>[];

  final pipeline = ref.watch(merchantLookupPipelineProvider);
  final matches = <String, MerchantMatch>{};
  for (final row in spend) {
    matches[row.name] = await pipeline.resolve(row.name);
  }

  return MerchantInterestScorer.fromMatches(spend, matches)
      .take(kCouponMerchantDepth)
      .map((i) => i.merchantId)
      .toList(growable: false);
});

/// Offers grouped by merchant — the "Stores" surface. Only merchants that
/// actually have a live offer appear, so the list can never advertise a shop
/// with nothing to show.
final couponsByMerchantProvider =
    FutureProvider<Map<String, List<CouponOffer>>>((ref) async {
  if (!ref.watch(merchantOffersEnabledProvider)) return const {};
  final offers = await ref.watch(couponsProvider.future);
  final grouped = <String, List<CouponOffer>>{};
  for (final offer in offers) {
    final id = offer.merchantId;
    if (id == null) continue;
    (grouped[id] ??= <CouponOffer>[]).add(offer);
  }
  return Map.unmodifiable(grouped);
});

/// The cached merchant catalog, for rendering names and logos.
final catalogMerchantsProvider =
    FutureProvider<Map<String, RemoteCatalogMerchant>>((ref) async {
  ref.watch(dbRevisionProvider);
  if (!ref.watch(merchantOffersEnabledProvider)) return const {};
  final all =
      await RemoteCatalogMerchantsDao(ref.watch(appDatabaseProvider)).getAll();
  return {for (final m in all) m.id: m};
});

/// "For You" — offers at merchants the user actually shops at, strongest first.
///
/// Empty when personalization is off, which is what makes the section simply
/// not render rather than showing an unpersonalized list under a personal
/// heading.
final forYouCouponsProvider = FutureProvider<List<CouponOffer>>((ref) async {
  final top = await ref.watch(topMerchantIdsProvider.future);
  if (top.isEmpty) return const <CouponOffer>[];
  final offers = await ref.watch(couponsProvider.future);
  final rank = {for (var i = 0; i < top.length; i++) top[i]: i};
  final mine = offers.where((o) => rank.containsKey(o.merchantId)).toList()
    ..sort((a, b) => rank[a.merchantId]!.compareTo(rank[b.merchantId]!));
  return List.unmodifiable(mine);
});

/// Eligible + ranked offers for the Offers screen.
///
/// Eligibility is re-applied on the DEVICE (never trusting that the cache is
/// fresh): the canonical live predicate plus country targeting. So a cached
/// offer that expired while the user was offline disappears immediately.
final couponsProvider = FutureProvider<List<CouponOffer>>((ref) async {
  if (!ref.watch(couponsEnabledProvider)) return const <CouponOffer>[];
  final offers = await ref.watch(cachedCouponsProvider.future);
  final country = await ref.watch(couponCountryProvider.future);
  final hints = await ref.watch(couponSpendHintsProvider.future);
  // Empty unless the flag is on AND the user opted in. The ranking has no
  // special case for "off"; it simply has nothing to score against, so the
  // order degrades to exactly what it was before Phase 1.
  final merchants = await ref.watch(topMerchantIdsProvider.future);
  return rankCoupons(
    offers,
    now: DateTime.now(),
    countryCode: country,
    topSpendCategoryKeys: hints,
    topMerchantIds: merchants,
  );
});

/// The dashboard teaser subset — the same ranking, capped.
final dashboardCouponsProvider = Provider<AsyncValue<List<CouponOffer>>>((ref) {
  if (!ref.watch(couponsEnabledProvider)) {
    return const AsyncValue<List<CouponOffer>>.data(<CouponOffer>[]);
  }
  return ref
      .watch(couponsProvider)
      .whenData((offers) => offers.take(kCouponTeaserLimit).toList(growable: false));
});

/// The display categories present in the currently eligible offers, in the
/// order those offers appear (deterministic because the ranking is).
final couponCategoriesProvider = Provider<AsyncValue<List<CouponCategory>>>((ref) {
  return ref.watch(couponsProvider).whenData((offers) {
    final seen = <String>{};
    return offers
        .map((o) => o.category)
        .where((c) => seen.add(c.key))
        .toList(growable: false);
  });
});

/// The tags present in the currently eligible offers, preserving the server's
/// deterministic per-offer order.
final couponTagsProvider = Provider<AsyncValue<List<CouponTag>>>((ref) {
  return ref.watch(couponsProvider).whenData((offers) {
    final seen = <String>{};
    return offers
        .expand((o) => o.tags)
        .where((t) => seen.add(t.key))
        .toList(growable: false);
  });
});

/// Process-lifetime analytics client (also owns the session impression /
/// detail-view dedup sets — see [CouponAnalyticsClient]).
final couponAnalyticsProvider = Provider<CouponAnalyticsClient>((ref) {
  final loadSettings = ref.watch(loadUserSettingsUseCaseProvider);
  return CouponAnalyticsClient(loadSettings: loadSettings.call);
});
