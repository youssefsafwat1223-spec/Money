import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import '../db/app_database.dart';
import 'announcement_service.dart';
import 'catalog_daos.dart';
import 'feature_flag_service.dart';

class CatalogSyncService {
  CatalogSyncService({
    required AppDatabase database,
    required supabase.SupabaseClient client,
    required CatalogMetadataDao metadataDao,
    required FeatureFlagService featureFlagService,
    required AnnouncementService announcementService,
  })  : _database = database,
        _client = client,
        _metadataDao = metadataDao,
        _featureFlagService = featureFlagService,
        _announcementService = announcementService;

  final AppDatabase _database;
  final supabase.SupabaseClient _client;
  final CatalogMetadataDao _metadataDao;
  final FeatureFlagService _featureFlagService;
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
      ]);
      // Refresh in-memory flag cache after sync
      await _featureFlagService.init();
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
          'X-App-Version': String.fromEnvironment('APP_VERSION'),
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
          'X-App-Version': String.fromEnvironment('APP_VERSION'),
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
        headers: const {'X-App-Version': String.fromEnvironment('APP_VERSION')},
        queryParameters: {
          'category': category,
          'since_version': sinceVersion,
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
      headers: const {'X-App-Version': String.fromEnvironment('APP_VERSION')},
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
