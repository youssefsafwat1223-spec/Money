import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../data/catalog/catalog_daos.dart';
import '../common/category_catalog.dart';
import 'coupon_analytics.dart';
import 'coupon_models.dart';
import 'coupon_ranking.dart';

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
  return rankCoupons(
    offers,
    now: DateTime.now(),
    countryCode: country,
    topSpendCategoryKeys: hints,
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
