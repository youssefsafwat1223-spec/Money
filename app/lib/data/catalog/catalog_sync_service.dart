import 'package:flutter/foundation.dart';
import '../../core/backend/app_version.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import '../db/app_database.dart';
import 'announcement_service.dart';
import 'catalog_daos.dart';
import 'parser_authority.dart';
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
      // AUTHORITY EPOCH — before anything else. An install already at the
      // server's parser version would never re-fetch, so a previous release's
      // bundled-active rules would keep money authority with no server event
      // able to dislodge them. This deactivates them once and forces one full
      // refresh; the epoch advances only after a VERIFIED snapshot, so an
      // outage leaves parsers inactive and retries next launch.
      final authority = ParserAuthority(
        RemoteParsersDao(_database),
        _metadataDao,
        _database,
      );
      final authorityAction = await authority.reconcile();
      final forceParsers =
          authorityAction == ParserAuthorityAction.refreshRequired;

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
      if (forceParsers && !stale.contains(CatalogCategories.parsers)) {
        stale.add(CatalogCategories.parsers);
      }
      await Future.wait([
        ...stale.map((c) => syncCategory(
              c,
              countryCode: countryCode,
              // A forced authority refresh must fetch the FULL set: at the
              // device's current version the delta would be empty, so nothing
              // would be reactivated even when the server says it is servable.
              fromZero: forceParsers && c == CatalogCategories.parsers,
            )),
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
    /// Ignore the stored version and request the FULL set. Used only by the
    /// authority-epoch refresh, where a delta at the device's current version
    /// would be empty and could therefore reactivate nothing.
    bool fromZero = false,
  }) async {
    if (!CatalogCategories.syncable.contains(category)) {
      debugPrint('Catalog sync ignored unsupported category: $category');
      return;
    }

    try {
      final local = await _metadataDao.getVersion(category);
      final sinceVersion = fromZero ? 0 : (local?.localVersion ?? 0);
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
      // Parsers only; absent for every other category.
      //
      // Revocation acts on an AUTHORITATIVE snapshot or not at all. Three ways
      // this can be untrustworthy, all of which must be inert rather than
      // destructive, because retention is one-way and a wrong revocation
      // cannot self-heal:
      //   * a malformed body (null/string/object) — `_stringList` turns any
      //     non-list into an empty list, which would read as "nothing is
      //     servable" and deactivate every rule;
      //   * a TRUNCATED page — indistinguishable from a full result without an
      //     explicit count, so the client would revoke everything beyond it;
      //   * a snapshot for a different catalog version than the items just
      //     applied — a torn read across concurrent writes.
      final meta = data['meta'];
      final serverVersion = meta is Map
          ? (meta['version'] as num?)?.toInt() ?? sinceVersion
          : sinceVersion;
      final servableIds = _authoritativeServableIds(data, serverVersion);

      await _database.transaction(() async {
        await _writeCategory(category, items, deletedIds, servableIds);
        // A forced refresh deactivated everything first precisely so nothing
        // serves without proof. The upsert above restores `is_active` from the
        // server row, so an UNVERIFIED response (old server, truncated,
        // malformed, stale) would quietly reactivate rules the epoch had just
        // revoked. Fail closed and retry next launch instead.
        if (fromZero &&
            category == CatalogCategories.parsers &&
            servableIds == null) {
          await RemoteParsersDao(_database).deactivateAll();
        }
        // The epoch advances ONLY here: inside the same transaction that
        // applied a snapshot the client already proved complete, current and
        // correctly counted. Offline, truncated, malformed or stale responses
        // never reach this line, so the forced refresh is retried next launch.
        if (category == CatalogCategories.parsers && servableIds != null) {
          await ParserAuthority(
            RemoteParsersDao(_database),
            _metadataDao,
            _database,
          ).markRefreshed();
        }
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

  /// The servable set, but only when the server PROVED the snapshot is
  /// complete and current. Returns null — meaning "do not revoke" — otherwise.
  ///
  /// Fail-open on revocation is the right default here: keeping a stale rule is
  /// recoverable by the next good sync, whereas mass-deactivating on a bad
  /// response is not, because reactivation only happens through an upsert the
  /// device will not receive while its version already matches.
  @visibleForTesting
  static List<String>? authoritativeServableIdsForTest(
    Map<dynamic, dynamic> data,
    int appliedVersion,
  ) =>
      _authoritativeServableIdsImpl(data, appliedVersion);

  List<String>? _authoritativeServableIds(
    Map<dynamic, dynamic> data,
    int appliedVersion,
  ) =>
      _authoritativeServableIdsImpl(data, appliedVersion);

  static List<String>? _authoritativeServableIdsImpl(
    Map<dynamic, dynamic> data,
    int appliedVersion,
  ) {
    final snapshot = data['servable_snapshot'];
    if (snapshot is! Map) return null;
    if (snapshot['complete'] != true) return null;

    final ids = snapshot['ids'];
    if (ids is! List) return null;
    // Genuine strings only. Coercing here would let a list of maps or numbers
    // become plausible-looking ids and revoke real rules.
    if (ids.any((e) => e is! String)) return null;
    final parsed = ids.cast<String>().toList(growable: false);

    // The count the server computed must equal what actually arrived.
    final count = snapshot['count'];
    if (count is! int || count != parsed.length) return null;

    final max = snapshot['max'];
    if (max is int && parsed.length > max) return null;

    // And it must describe the same catalog version as the items applied.
    final snapshotVersion = snapshot['catalog_version'];
    if (snapshotVersion is! int || snapshotVersion != appliedVersion) return null;

    return parsed;
  }

  Future<void> _writeCategory(
    String category,
    List<Map<String, Object?>> items,
    List<String> deletedIds,
    List<String>? servableIds,
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
        // Authoritative revocation. Applied only when the server actually sent
        // the set: a response without the key is an OLD server, and inventing
        // an empty set there would deactivate every rule on the device.
        if (servableIds != null) {
          await dao.applyAuthoritativeServableSet(servableIds);
        }
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
      case CatalogCategories.catalogMerchants:
        final dao = RemoteCatalogMerchantsDao(_database);
        await dao.upsertAll(items.map(RemoteCatalogMerchant.fromJson).toList());
        await dao.markDeleted(deletedIds);
      case CatalogCategories.merchantAliases:
        final dao = RemoteMerchantAliasesDao(_database);
        await dao.upsertAll(items.map(RemoteMerchantAlias.fromJson).toList());
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

/// Test seam for the authoritative-snapshot contract.
///
/// The decision is pure and is the one that decides whether a device revokes
/// parser authority, so it is worth testing directly rather than only through a
/// full sync with a fake transport.
@visibleForTesting
List<String>? debugAuthoritativeServableIds(
  Map<dynamic, dynamic> body,
  int appliedVersion,
) =>
    CatalogSyncService.authoritativeServableIdsForTest(body, appliedVersion);
