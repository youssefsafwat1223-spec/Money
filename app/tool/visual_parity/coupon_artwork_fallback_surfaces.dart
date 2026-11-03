// Actual public CouponCard non-HTTPS artwork fallback over owned local catalog.
import 'dart:async';
import 'dart:convert';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:money_companion/core/backend/supabase_config.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/i18n/locale_provider.dart';
import 'package:money_companion/core/theme/app_colors.dart';
import 'package:money_companion/core/theme/app_spacing.dart';
import 'package:money_companion/data/catalog/catalog_daos.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/features/cards/brand_mark.dart';
import 'package:money_companion/features/coupons/coupon_models.dart';
import 'package:money_companion/features/coupons/coupons_providers.dart';
import 'package:money_companion/features/coupons/coupon_widgets.dart';
import 'package:money_companion/features/settings/settings_providers.dart';

const visualParityCouponArtworkFallbackKeys = ['couponNonhttpsFallback'];
final _events = <String, int>{};
final _receipts = <String, Map<String, Object?>>{};
Map<String, int> visualParityCouponArtworkFallbackEvents() =>
    Map.unmodifiable(_events);
Map<String, Map<String, Object?>> visualParityCouponArtworkFallbackReceipts() =>
    Map.unmodifiable(_receipts);
void _record(String key) =>
    _events.update(key, (n) => n + 1, ifAbsent: () => 1);
Future<String> _snapshot(AppDatabase db) async {
  final tables = await db
      .customSelect(
          "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
      .get();
  return jsonEncode({
    for (final table in tables)
      table.read<String>('name'): (await db
              .customSelect(
                  'SELECT * FROM "${table.read<String>('name')}" ORDER BY rowid')
              .get())
          .map((r) => r.data)
          .toList()
  });
}

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'owned-coupon-art-memory';
  @override
  Future<String?> readStoredKey() async => 'owned-coupon-art-memory';
}

Future<bool> openVisualParityCouponArtworkFallback(
    BuildContext context, WidgetRef ref, String key) async {
  if (!visualParityCouponArtworkFallbackKeys.contains(key)) return false;
  if (!kDebugMode || SupabaseConfig.isConfigured) {
    throw StateError('coupon_art_requires_offline_debug');
  }
  if (!context.mounted) return false;
  final locale = Localizations.localeOf(context);
  final parent = ref.read(appDatabaseProvider);
  final databases = await parent.customSelect('PRAGMA database_list').get();
  if (!databases.any((row) =>
      row.read<String>('name') == 'main' && row.read<String>('file').isEmpty)) {
    throw StateError('coupon_art_requires_memory_database');
  }
  final db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _Keys(),
      initialLanguage: 'en');
  ProviderContainer? container;
  String? baseline;
  Future<void>? closing;
  Future<void> close() => closing ??= (() async {
        try {
          if (baseline != null) {
            final unchanged = await _snapshot(db) == baseline;
            _receipts[key] = Map.unmodifiable({
              ..._receipts[key]!,
              'childAllSqlUnchanged': unchanged,
              'phase': 'closed'
            });
            if (!unchanged) throw StateError('coupon_art_child_sql_changed');
            _record('${key}AllSqlUnchanged');
          }
        } finally {
          container?.dispose();
          await db.close();
          _record('${key}Closed');
        }
      })();
  try {
    const invalid = 'http://fixture.invalid/logo.png';
    await RemoteCouponsDao(db).replaceAll([
      CouponOffer(
          id: 'qa-invalid-art',
          slug: 'qa-invalid-art',
          partnerName: 'APPLE',
          titleAr: 'عرض تجريبي محلي',
          titleEn: 'Local synthetic offer',
          descriptionAr: 'صورة غير آمنة؛ يُعرض الشعار المرفق.',
          descriptionEn: 'Non-HTTPS artwork uses the bundled mark.',
          redemptionType: CouponRedemptionType.code,
          code: 'QAART',
          imageUrl: invalid,
          category: const CouponCategory(
              key: 'shopping', labelAr: 'تسوق', labelEn: 'Shopping'),
          validFrom: DateTime.utc(2020),
          validUntil: DateTime.utc(2040))
    ]);
    container = ProviderContainer(overrides: [
      appDatabaseProvider.overrideWithValue(db),
      localeProvider.overrideWithValue(locale)
    ]);
    final settings = await container.read(userSettingsProvider.future);
    if (settings.cloudProcessingEnabled ||
        container.read(remoteMerchantLogosAllowedProvider)) {
      throw StateError('coupon_art_requires_actual_denied_consent');
    }
    final cached = await container.read(cachedCouponsProvider.future);
    if (cached.length != 1 || cached.single.imageUrl != invalid) {
      throw StateError('coupon_art_actual_cache_changed');
    }
    final offer = cached.single;
    baseline = await _snapshot(db);
    _receipts[key] = Map.unmodifiable({
      'syntheticOnly': true,
      'couponId': offer.id,
      'imageUrl': offer.imageUrl,
      'partnerName': offer.partnerName,
      'actualCloudProcessingEnabled': settings.cloudProcessingEnabled,
      'actualRemoteLogosAllowed':
          container.read(remoteMerchantLogosAllowedProvider),
      'phase': 'ready'
    });
    if (!context.mounted) {
      await close();
      return false;
    }
    _record('${key}Opened');
    final owned = container;
    unawaited(Navigator.of(context)
        .push<void>(MaterialPageRoute<void>(
            builder: (_) => _Lifetime(
                close: close,
                child: UncontrolledProviderScope(
                    container: owned,
                    child: Builder(
                        builder: (context) => Scaffold(
                            backgroundColor: context.colors.bg,
                            appBar: AppBar(
                                title: const Text('Bundled artwork fallback')),
                            body: SingleChildScrollView(
                                padding: const EdgeInsets.all(AppSpacing.s4),
                                child: RepaintBoundary(
                                    key:
                                        const ValueKey('coupon-artwork-raster'),
                                    child: CouponCard(
                                        offer: offer,
                                        onTap: () {
                                          _record('${key}ForbiddenTap');
                                          throw StateError(
                                              'coupon_art_read_only');
                                        })))))))))
        .whenComplete(close));
    return true;
  } catch (_) {
    await close();
    rethrow;
  }
}

class _Lifetime extends StatefulWidget {
  const _Lifetime({required this.close, required this.child});
  final Future<void> Function() close;
  final Widget child;
  @override
  State<_Lifetime> createState() => _LifetimeState();
}

class _LifetimeState extends State<_Lifetime> {
  @override
  void dispose() {
    unawaited(widget.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
