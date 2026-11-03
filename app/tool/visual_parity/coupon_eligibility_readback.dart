// Read-only catalog diagnostics for the disposable preview; never imported by lib.
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:money_companion/core/backend/supabase_config.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/features/coupons/coupons_providers.dart';

Future<Map<String, Object?>> readVisualParityCouponEligibility(
    ProviderContainer container) async {
  if (!kDebugMode || SupabaseConfig.isConfigured) {
    throw StateError('coupon_readback_requires_offline_debug');
  }
  final db = container.read(appDatabaseProvider);
  final databases = await db.customSelect('PRAGMA database_list').get();
  if (!databases.any((row) =>
      row.read<String>('name') == 'main' && row.read<String>('file').isEmpty)) {
    throw StateError('coupon_readback_requires_memory_database');
  }
  final cached = await container.read(cachedCouponsProvider.future);
  final eligible = await container.read(couponsProvider.future);
  final country = await container.read(couponCountryProvider.future);
  return {
    'syntheticOnly': true,
    'country': country,
    'contentEnabled': container.read(couponsEnabledProvider),
    'affiliateTracking': container.read(affiliateTrackingEnabledProvider),
    'personalization':
        await container.read(merchantPersonalizationEnabledProvider.future),
    'cachedIds': cached.map((offer) => offer.id).toList(),
    'eligibleIds': eligible.map((offer) => offer.id).toList(),
    'cachedTitles': [
      for (final offer in cached)
        {'id': offer.id, 'ar': offer.titleAr, 'en': offer.titleEn}
    ],
  };
}
