import 'package:flutter/foundation.dart';
import '../../core/backend/app_version.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import '../db/app_database.dart';
import 'announcement_service.dart';
import 'catalog_daos.dart';
import '../../core/observability/diagnostics.dart';
import '../../core/observability/telemetry_error.dart';
import '../../features/coupons/coupon_models.dart';

class CatalogSyncService {
  CatalogSyncService({
    required AppDatabase database,
    required supabase.SupabaseClient client,
    required CatalogMetadataDao metadataDao,
    required AnnouncementService announcementService,
  })  : _database = database,
        _client = client,
        _metadataDao = metadataDao,
        _announcementService = announcementService;

  final AppDatabase _database;
  final supabase.SupabaseClient _client;
  final CatalogMetadataDao _metadataDao;
  // ignore: unused_field
  final AnnouncementService _announcementService;

  Future<void> syncAll({String? countryCode}) async {
    try {
      // Delta sync for versioned categories
      final versions = await _fetchVersions();
      final stale = <String>[];
      for (final category in CatalogCategories.syncable) {
        final serverVersion = versions[category] ?? 0;
        final local = await _metadataDao.getVersion(category);
        final localVersion = local?.localVersion ?? 0;
        if (serverVersion > localVersion) {
          stale.add(category);
        }
      }
      await Future.wait([
        ...stale.map((c) => syncCategory(c, countryCode: countryCode)),
        syncFlags(countryCode: countryCode),
        syncAnnouncements(countryCode: countryCode),
        syncGrowthCampaigns(countryCode: countryCode),
        syncCoupons(),
      ]);
    } catch (error, stackTrace) {
      debugPrint('Catalog sync skipped: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<void> syncFlags({String? countryCode}) async {
    try {
      final response = await _client.functions.invoke(
        'catalog-flags',
        method: supabase.HttpMethod.get,
        headers: const {
          ...kAppVersionHeaders,
        },
        queryParameters: {
          if (countryCode != null && countryCode.isNotEmpty)
            'country': countryCode.trim().toUpperCase(),
        },
      );
      if (response.status < 200 || response.status >= 300) return;
      final data = response.data;
      final items = data is List
          ? data
          : data is Map && data['flags'] is List
              ? data['flags'] as List
              : <Object?>[];
      final flags = items
          .whereType<Map<Object?, Object?>>()
          .map((m) => m.map((k, v) => MapEntry(k.toString(), v)))
          .map(RemoteFeatureFlag.fromJson)
          .toList();
      await RemoteFeatureFlagsDao(_database).replaceAll(flags);
    } catch (e) {
      debugPrint('Catalog flags sync skipped: $e');
    }
  }

  Future<void> syncAnnouncements({String? countryCode}) async {
    try {
      final response = await _client.functions.invoke(
        'catalog-announcements',
        method: supabase.HttpMethod.get,
        headers: const {
          ...kAppVersionHeaders,
        },
        queryParameters: {
          if (countryCode != null && countryCode.isNotEmpty)
            'country': countryCode.trim().toUpperCase(),
        },
      );
      if (response.status < 200 || response.status >= 300) return;
      final data = response.data;
      final items = data is List
          ? data
          : data is Map && data['announcements'] is List
              ? data['announcements'] as List
              : <Object?>[];
      final announcements = items
          .whereType<Map<Object?, Object?>>()
          .map((m) => m.map((k, v) => MapEntry(k.toString(), v)))
          .map(RemoteAnnouncement.fromJson)
          .toList();
      await RemoteAnnouncementsDao(_database).replaceAll(announcements);
    } catch (e) {
      debugPrint('Catalog announcements sync skipped: $e');
    }
  }

  Future<void> syncGrowthCampaigns({String? countryCode}) async {
    try {
      final response = await _client.functions.invoke(
        'catalog-campaigns',
        method: supabase.HttpMethod.get,
        headers: const {
          ...kAppVersionHeaders,
        },
        queryParameters: {
          if (countryCode != null && countryCode.isNotEmpty)
            'country': countryCode.trim().toUpperCase(),
        },
      );
      if (response.status < 200 || response.status >= 300) return;
      final data = response.data;
      final items = data is List
          ? data
          : data is Map && data['campaigns'] is List
              ? data['campaigns'] as List
              : <Object?>[];
      final campaigns = items
          .whereType<Map<Object?, Object?>>()
          .map((m) => m.map((k, v) => MapEntry(k.toString(), v)))
          .map(RemoteGrowthCampaign.fromJson)
          .toList();
      await RemoteGrowthCampaignsDao(_database).replaceAll(campaigns);
    } catch (e) {
      debugPrint('Catalog campaigns sync skipped: $e');
    }
  }

  /// MALI-COUPONS (Phase C4) — pull the live Offers catalog and replace the
  /// local cache ATOMICALLY.
  ///
  /// Contract:
  ///   * a successful snapshot replaces the cache in ONE transaction;
  ///   * an EMPTY successful snapshot legitimately clears the cache — it is
  ///     never mistaken for a failure;
  ///   * ANY failure (transport, non-2xx, malformed body, decode/insert error)
  ///     leaves the previous cache untouched, because `replaceAll` is only ever
  ///     called with a fully decoded list and rolls back as a unit;
  ///   * it never throws: coupons are a non-critical feature and must not break
  ///     catalog sync, startup or any financial flow.
  ///
  /// No country is sent: eligibility is a render-time decision on the device,
  /// so a client-supplied country never becomes a server-side filter.
  Future<void> syncCoupons() async {
    try {
      final response = await _client.functions.invoke(
        'catalog-coupons',
        method: supabase.HttpMethod.get,
        headers: const {
          ...kAppVersionHeaders,
        },
      );
      if (response.status < 200 || response.status >= 300) return;
      final data = response.data;
      final items = data is List
          ? data
          : data is Map && data['items'] is List
              ? data['items'] as List
              : null;
      // A missing/unrecognised envelope is a FAILURE, not an empty catalog:
      // returning here preserves the previous cache.
      if (items == null) {
        Diag.error('[CatalogCoupons] $_couponSnapshotTelemetry',
            'malformed envelope — previous cache preserved');
        return;
      }

      // ALL-OR-NOTHING. The whole snapshot is validated and mapped BEFORE the
      // database is touched: `replaceAll` only ever receives a fully typed,
      // fully validated catalog, so a destructive replace can never begin
      // against a payload that turns out to be invalid partway through.
      final List<CouponOffer> offers;
      try {
        offers = CouponOffer.parseSnapshot(items);
      } on CouponSnapshotException catch (error) {
        // A catalog-CONTRACT error, not a transport error. One bad row rejects
        // the entire snapshot and the last-known-good cache survives untouched
        // — a partially-valid catalog must never replace a good one.
        Diag.error('[CatalogCoupons] $_couponSnapshotTelemetry', error);
        return;
      }

      await RemoteCouponsDao(_database).replaceAll(offers);
    } catch (e) {
      Diag.error('[CatalogCoupons]', e);
    }
  }

  /// Stable, data-free telemetry identity for a rejected coupon catalog
  /// snapshot. Only the code plus the allowlisted module/operation survive the
  /// Sentry boundary — no server content and no user data.
  static const TelemetryError _couponSnapshotTelemetry = TelemetryError(
    TelemetryCodes.syncDecodeFailed,
    module: 'sync',
    operation: 'catalog_coupons',
    retryable: false,
  );

  Future<void> syncCategory(
    String category, {
    String? countryCode,
  }) async {
    if (!CatalogCategories.syncable.contains(category)) {
      debugPrint('Catalog sync ignored unsupported category: $category');
      return;
    }

    try {
      final local = await _metadataDao.getVersion(category);
      final sinceVersion = local?.localVersion ?? 0;
      final response = await _client.functions.invoke(
        'catalog-delta',
        method: supabase.HttpMethod.get,
        headers: kAppVersionHeaders,
        queryParameters: {
          'category': category,
          'since_version': sinceVersion.toString(),
          if (countryCode != null && countryCode.trim().isNotEmpty)
            'country': countryCode.trim().toUpperCase(),
        },
      );

      if (response.status < 200 || response.status >= 300) {
        debugPrint('Catalog delta $category failed: HTTP ${response.status}');
        return;
      }

      final data = response.data;
      if (data is! Map) {
        debugPrint('Catalog delta $category returned invalid JSON');
        return;
      }

      final items = _listOfMaps(data['items']);
      final deletedIds = _stringList(data['deleted_ids']);
      final meta = data['meta'];
      final serverVersion = meta is Map
          ? (meta['version'] as num?)?.toInt() ?? sinceVersion
          : sinceVersion;

      await _database.transaction(() async {
        await _writeCategory(category, items, deletedIds);
        final syncedAt = DateTime.now().toUtc();
        await _metadataDao.upsertVersion(
          category,
          serverVersion,
          serverVersion,
        );
        await _metadataDao.setLastSynced(category, syncedAt);
      });
    } catch (error, stackTrace) {
      debugPrint('Catalog category sync skipped for $category: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<Map<String, int>> _fetchVersions() async {
    final response = await _client.functions.invoke(
      'catalog-versions',
      method: supabase.HttpMethod.get,
      headers: kAppVersionHeaders,
    );
    if (response.status < 200 || response.status >= 300) {
      throw StateError('catalog-versions HTTP ${response.status}');
    }

    final data = response.data;
    if (data is! Map) {
      throw const FormatException('catalog-versions returned invalid JSON');
    }
    return data.map((key, value) {
      return MapEntry(key.toString(), (value as num?)?.toInt() ?? 0);
    });
  }

  Future<void> _writeCategory(
    String category,
    List<Map<String, Object?>> items,
    List<String> deletedIds,
  ) async {
    switch (category) {
      case CatalogCategories.banks:
        final dao = RemoteBanksDao(_database);
        await dao.upsertAll(items.map(RemoteBank.fromJson).toList());
        await dao.markDeleted(deletedIds);
      case CatalogCategories.parsers:
        final dao = RemoteParsersDao(_database);
        await dao.upsertAll(items.map(RemoteParser.fromJson).toList());
        await dao.markDeleted(deletedIds);
      case CatalogCategories.currencies:
        final dao = RemoteCurrenciesDao(_database);
        await dao.upsertAll(items.map(RemoteCurrency.fromJson).toList());
        await dao.markDeleted(deletedIds);
      case CatalogCategories.countries:
        final dao = RemoteCountriesDao(_database);
        await dao.upsertAll(items.map(RemoteCountry.fromJson).toList());
        await dao.markDeleted(deletedIds);
      case CatalogCategories.categories:
        final dao = RemoteCategoriesDao(_database);
        await dao.upsertAll(items.map(RemoteCategory.fromJson).toList());
        await dao.markDeleted(deletedIds);
      case CatalogCategories.merchantKeywords:
        final dao = RemoteMerchantKeywordsDao(_database);
        await dao.upsertAll(items.map(RemoteMerchantKeyword.fromJson).toList());
        await dao.markDeleted(deletedIds);
    }
  }

  List<Map<String, Object?>> _listOfMaps(Object? value) {
    if (value is! List) return const [];
    return value
        .whereType<Map<Object?, Object?>>()
        .map(
          (item) => item.map(
            (key, value) => MapEntry(key.toString(), value),
          ),
        )
        .toList(growable: false);
  }

  List<String> _stringList(Object? value) {
    if (value is! List) return const [];
    return value.map((item) => item.toString()).toList(growable: false);
  }
}
