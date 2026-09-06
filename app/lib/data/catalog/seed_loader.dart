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

    // PARSERS — seeded INACTIVE. This is the bundled-asset bypass, closed.
    //
    // The server gate admits a parser only once it has passed golden-test
    // validation (catalog-delta checks validation_status/validated_at/
    // golden_test_count). The bundle carried no validation metadata at all, so
    // seeding it active made every unvalidated rule the device's first parsing
    // authority — the exact authority the gate exists to withhold. It also
    // meant a rule revoked on the server was resurrected by any wipe/reinstall,
    // and an offline first run silently activated rules that may never be
    // servable. Today NONE of the twelve is validated, so the bundle's whole
    // content is rules the server refuses to serve.
    //
    // Seeding inactive keeps first-run and offline behaviour deterministic —
    // the rows are present, versioned at 0, and the very first successful sync
    // upserts and activates whatever the server actually serves — while making
    // it impossible for an outage to activate a rule on the device's own say-so.
    // Parsing is unaffected in kind: the engine's own heuristics remain the
    // authority until a validated catalog rule arrives, which is what happens
    // in production today regardless, since catalog-delta serves no parsers.
    if (await db.count('remote_parsers') == 0) {
      final parsers = await _readJsonList(
        'assets/catalog/parsers.json',
        RemoteParser.fromJson,
      );
      // Inactive AT INSERT, not deactivated afterwards: an upsert-then-revoke
      // pair is not atomic, and a crash between them would leave the entire
      // bundle active with the nonempty-table check skipping the repair on
      // every later run.
      await parsersDao.upsertAll([
        for (final p in parsers) p.copyWithActive(false),
      ]);
      await metadataDao.upsertVersion(CatalogCategories.parsers, 0, 0);
      debugPrint(
        'Catalog seed: seeded parsers INACTIVE (${parsers.length}) — '
        'activation requires a validated rule from catalog-delta',
      );
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

    // COUPONS Phase 1 — the merchant catalog ships empty and arrives entirely
    // by sync, exactly like merchant_keywords above. The metadata row is the
    // load-bearing part: CatalogSyncService tracks a category by its version
    // row, so a category with no row is a category that never asks the server
    // for a delta. Seeding no data and no metadata would have left the merchant
    // catalog permanently empty on every install, with nothing failing.
    if (await db.count('remote_catalog_merchants') == 0) {
      await metadataDao.upsertVersion(CatalogCategories.catalogMerchants, 0, 0);
      debugPrint('Catalog seed: seeded catalog_merchants (0)');
    } else {
      debugPrint('Catalog seed: skipped catalog_merchants (already had data)');
    }

    if (await db.count('remote_merchant_aliases') == 0) {
      await metadataDao.upsertVersion(CatalogCategories.merchantAliases, 0, 0);
      debugPrint('Catalog seed: seeded merchant_aliases (0)');
    } else {
      debugPrint('Catalog seed: skipped merchant_aliases (already had data)');
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
      debugPrint(
          'Catalog seed: seeded announcements (${announcements.length})');
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
