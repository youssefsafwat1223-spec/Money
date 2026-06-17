import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../db/app_database.dart';
import 'catalog_daos.dart';

class SeedLoader {
  const SeedLoader();

  Future<void> seedIfEmpty(AppDatabase db) async {
    final banksDao = RemoteBanksDao(db);
    final parsersDao = RemoteParsersDao(db);
    final currenciesDao = RemoteCurrenciesDao(db);
    final countriesDao = RemoteCountriesDao(db);
    final categoriesDao = RemoteCategoriesDao(db);
    final flagsDao = RemoteFeatureFlagsDao(db);
    final announcementsDao = RemoteAnnouncementsDao(db);
    final metadataDao = CatalogMetadataDao(db);

    if (await db.count('remote_banks') == 0) {
      final banks = await _readJsonList(
        'assets/catalog/banks.json',
        RemoteBank.fromJson,
      );
      await banksDao.upsertAll(banks);
      await metadataDao.upsertVersion(CatalogCategories.banks, 0, 0);
      debugPrint('Catalog seed: seeded banks (${banks.length})');
    } else {
      debugPrint('Catalog seed: skipped banks (already had data)');
    }

    if (await db.count('remote_parsers') == 0) {
      final parsers = await _readJsonList(
        'assets/catalog/parsers.json',
        RemoteParser.fromJson,
      );
      await parsersDao.upsertAll(parsers);
      await metadataDao.upsertVersion(CatalogCategories.parsers, 0, 0);
      debugPrint('Catalog seed: seeded parsers (${parsers.length})');
    } else {
      debugPrint('Catalog seed: skipped parsers (already had data)');
    }

    // Currencies and countries are small static reference data — always upsert
    // so that fixes to the bundled JSON are picked up without a reinstall.
    final currencies = await _readJsonList(
      'assets/catalog/currencies.json',
      RemoteCurrency.fromJson,
    );
    await currenciesDao.upsertAll(currencies);
    await metadataDao.upsertVersion(CatalogCategories.currencies, 0, 0);
    debugPrint('Catalog seed: seeded currencies (${currencies.length})');

    final countries = await _readJsonList(
      'assets/catalog/countries.json',
      RemoteCountry.fromJson,
    );
    await countriesDao.upsertAll(countries);
    await metadataDao.upsertVersion(CatalogCategories.countries, 0, 0);
    debugPrint('Catalog seed: seeded countries (${countries.length})');

    if (await db.count('remote_categories') == 0) {
      final categories = await _readJsonList(
        'assets/catalog/categories.json',
        RemoteCategory.fromJson,
      );
      await categoriesDao.upsertAll(categories);
      await metadataDao.upsertVersion(CatalogCategories.categories, 0, 0);
      debugPrint('Catalog seed: seeded categories (${categories.length})');
    } else {
      debugPrint('Catalog seed: skipped categories (already had data)');
    }

    if (await db.count('remote_feature_flags') == 0) {
      final flags = await _readJsonList(
        'assets/catalog/feature_flags.json',
        RemoteFeatureFlag.fromJson,
      );
      await flagsDao.replaceAll(flags);
      debugPrint('Catalog seed: seeded feature_flags (${flags.length})');
    } else {
      debugPrint('Catalog seed: skipped feature_flags (already had data)');
    }

    // Merchant keywords seed is always empty — entries come from remote sync only.
    // Register the metadata entry so CatalogSyncService can track versions.
    if (await db.count('remote_merchant_keywords') == 0) {
      await metadataDao.upsertVersion(CatalogCategories.merchantKeywords, 0, 0);
      debugPrint('Catalog seed: seeded merchant_keywords (0)');
    } else {
      debugPrint('Catalog seed: skipped merchant_keywords (already had data)');
    }

    // Announcements seed is always empty — no hard-coded announcements.
    if (await db.count('remote_announcements') == 0) {
      final announcements = await _readJsonList(
        'assets/catalog/announcements.json',
        RemoteAnnouncement.fromJson,
      );
      if (announcements.isNotEmpty) {
        await announcementsDao.replaceAll(announcements);
      }
      debugPrint('Catalog seed: seeded announcements (${announcements.length})');
    }
  }

  Future<List<T>> _readJsonList<T>(
    String assetPath,
    T Function(Map<String, Object?> json) fromJson,
  ) async {
    final raw = await rootBundle.loadString(assetPath);
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      throw const FormatException('Catalog seed asset must be a JSON array');
    }
    return decoded
        .whereType<Map<String, Object?>>()
        .map(fromJson)
        .toList(growable: false);
  }
}
