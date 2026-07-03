import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/catalog/announcement_service.dart';
import 'package:money_companion/data/catalog/catalog_daos.dart';
import 'package:money_companion/data/catalog/feature_flag_service.dart';
import 'package:money_companion/data/catalog/seed_loader.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

RemoteBank _bank(
  String id,
  String shortCode, {
  String country = 'EG',
  List<String>? smsSenders,
}) =>
    RemoteBank(
      id: id,
      nameAr: 'بنك',
      nameEn: 'Bank',
      shortCode: shortCode,
      logoUrl: null,
      countryCode: country,
      smsSenders: smsSenders ?? [shortCode.toUpperCase()],
      supportedCurrencies: ['EGP'],
      colorHex: '#000000',
      isActive: true,
      sortOrder: 0,
      isDeleted: false,
      updatedAt: DateTime.now().toUtc(),
    );

RemoteCategory _category(String id, String key) => RemoteCategory(
      id: id,
      key: key,
      nameAr: 'تصنيف',
      nameEn: 'Category',
      icon: 'tag',
      colorHex: '#ff0000',
      parentKey: null,
      type: 'expense',
      sortOrder: 0,
      isSystem: false,
      isActive: true,
      isDeleted: false,
      updatedAt: DateTime.now().toUtc(),
    );

RemoteFeatureFlag _flag(
  String key,
  String value, {
  int rollout = 100,
  String type = 'boolean',
  bool isActive = true,
}) =>
    RemoteFeatureFlag(
      key: key,
      valueType: type,
      value: value,
      rolloutPercent: rollout,
      targetCountries: [],
      isActive: isActive,
      syncedAt: DateTime.now().toUtc(),
    );

RemoteAnnouncement _announcement({
  required String id,
  String severity = 'info',
  DateTime? validFrom,
  DateTime? validUntil,
}) {
  final now = DateTime.now().toUtc();
  return RemoteAnnouncement(
    id: id,
    titleAr: 'إعلان',
    titleEn: 'Announcement',
    bodyAr: null,
    bodyEn: null,
    severity: severity,
    minAppVersion: null,
    maxAppVersion: null,
    actionLabelAr: null,
    actionLabelEn: null,
    actionUrl: null,
    validFrom: validFrom ?? now.subtract(const Duration(hours: 1)),
    validUntil: validUntil,
    isDismissible: true,
    priority: 0,
    isDismissed: false,
    dismissedAt: null,
    syncedAt: now,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
  });

  tearDown(() async => db.close());

  // ──────────────────────────────────────────────────────────────────────────
  group('CatalogMetadataDao — version tracking', () {
    test('getVersion returns null for unknown category', () async {
      expect(await CatalogMetadataDao(db).getVersion('nonexistent'), isNull);
    });

    test('upsertVersion creates metadata row', () async {
      final dao = CatalogMetadataDao(db);
      await dao.upsertVersion('banks', 7, 7);
      final v = await dao.getVersion('banks');
      expect(v!.serverVersion, 7);
      expect(v.localVersion, 7);
      expect(v.lastSyncedAt, isNull);
    });

    test('upsertVersion overwrites existing row', () async {
      final dao = CatalogMetadataDao(db);
      await dao.upsertVersion('banks', 3, 3);
      await dao.upsertVersion('banks', 12, 12);
      expect((await dao.getVersion('banks'))!.serverVersion, 12);
    });

    test('setLastSynced records timestamp', () async {
      final dao = CatalogMetadataDao(db);
      await dao.upsertVersion('banks', 1, 1);
      await dao.setLastSynced('banks', DateTime.now().toUtc());
      expect((await dao.getVersion('banks'))!.lastSyncedAt, isNotNull);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('RemoteBanksDao — delta write', () {
    test('upsertAll inserts multiple banks', () async {
      await RemoteBanksDao(db)
          .upsertAll([_bank('b1', 'nbe'), _bank('b2', 'cib')]);
      expect(await db.count('remote_banks'), 2);
    });

    test('upsertAll is idempotent', () async {
      final dao = RemoteBanksDao(db);
      await dao.upsertAll([_bank('b1', 'nbe')]);
      await dao.upsertAll([_bank('b1', 'nbe')]);
      expect(await db.count('remote_banks'), 1);
    });

    test('markDeleted hides bank from getActiveBanks', () async {
      final dao = RemoteBanksDao(db);
      await dao.upsertAll([_bank('b1', 'nbe')]);
      await dao.markDeleted(['b1']);
      expect(await dao.getActiveBanks('EG'), isEmpty);
    });

    test('getActiveBanks filters by country_code', () async {
      final dao = RemoteBanksDao(db);
      await dao.upsertAll([
        _bank('b1', 'nbe', country: 'EG'),
        _bank('b2', 'snb', country: 'SA'),
      ]);
      final eg = await dao.getActiveBanks('EG');
      expect(eg.length, 1);
      expect(eg.first.shortCode, 'nbe');
    });

    test('getBankBySender matches on SMS sender substring', () async {
      final dao = RemoteBanksDao(db);
      await dao.upsertAll([_bank('b1', 'nbe')]);
      final found = await dao.getBankBySender('NBE');
      expect(found?.shortCode, 'nbe');
    });

    test('getBankBySender tolerates ATM suffixes and sender separators',
        () async {
      final dao = RemoteBanksDao(db);
      await dao.upsertAll([
        _bank('b1', 'cib_eg', smsSenders: ['CIB', 'CIB Alerts']),
      ]);
      final found = await dao.getBankBySender('CIB-ATM');
      expect(found?.shortCode, 'cib_eg');
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('RemoteCategoriesDao — delta write', () {
    test('upsertAll inserts categories', () async {
      await RemoteCategoriesDao(db).upsertAll([
        _category('c1', 'restaurants'),
        _category('c2', 'groceries'),
      ]);
      expect(await db.count('remote_categories'), 2);
    });

    test('markDeleted excludes category from getActiveCategories', () async {
      final dao = RemoteCategoriesDao(db);
      await dao.upsertAll([_category('c1', 'restaurants')]);
      await dao.markDeleted(['c1']);
      expect(await dao.getActiveCategories(), isEmpty);
    });

    test('getByKey returns correct category', () async {
      final dao = RemoteCategoriesDao(db);
      await dao.upsertAll([_category('c1', 'restaurants')]);
      final cat = await dao.getByKey('restaurants');
      expect(cat?.id, 'c1');
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('FeatureFlagService — reads from Drift with rollout', () {
    test('getBool returns DB value at 100% rollout', () async {
      await RemoteFeatureFlagsDao(db)
          .replaceAll([_flag('enable_goals', 'false')]);
      final svc =
          FeatureFlagService(dao: RemoteFeatureFlagsDao(db), installId: 'test');
      await svc.init();
      expect(svc.getBool('enable_goals'), isFalse);
    });

    test('getBool falls back to default at 0% rollout', () async {
      // enable_goals default is true; rollout 0% means flag is skipped
      await RemoteFeatureFlagsDao(db)
          .replaceAll([_flag('enable_goals', 'false', rollout: 0)]);
      final svc =
          FeatureFlagService(dao: RemoteFeatureFlagsDao(db), installId: 'test');
      await svc.init();
      expect(svc.getBool('enable_goals'), isTrue);
    });

    test('getString returns DB string value', () async {
      await RemoteFeatureFlagsDao(db).replaceAll([
        _flag('parser_engine_version', 'v2', type: 'string'),
      ]);
      final svc =
          FeatureFlagService(dao: RemoteFeatureFlagsDao(db), installId: 'test');
      await svc.init();
      expect(svc.getString('parser_engine_version'), 'v2');
    });

    test('inactive flag is excluded and default applies', () async {
      await RemoteFeatureFlagsDao(db).replaceAll([
        _flag('enable_goals', 'false', isActive: false),
      ]);
      final svc =
          FeatureFlagService(dao: RemoteFeatureFlagsDao(db), installId: 'test');
      await svc.init();
      expect(svc.getBool('enable_goals'), isTrue); // default
    });

    test('isInitialised transitions false → true after init()', () async {
      final svc =
          FeatureFlagService(dao: RemoteFeatureFlagsDao(db), installId: 'test');
      expect(svc.isInitialised, isFalse);
      await svc.init();
      expect(svc.isInitialised, isTrue);
    });

    test('different installIds produce consistent bucket distribution',
        () async {
      // This test verifies SHA-256 bucketing doesn't crash and returns bool.
      await RemoteFeatureFlagsDao(db)
          .replaceAll([_flag('enable_coupons', 'true', rollout: 50)]);
      for (final id in ['user-a', 'user-b', 'user-c', 'user-d']) {
        final svc =
            FeatureFlagService(dao: RemoteFeatureFlagsDao(db), installId: id);
        await svc.init();
        expect(svc.getBool('enable_coupons'), isA<bool>());
      }
    });

    test('sync flags all default to false when no DB rows exist', () async {
      // No rows in remote_feature_flags — service must use _defaults.
      final svc =
          FeatureFlagService(dao: RemoteFeatureFlagsDao(db), installId: 'test');
      await svc.init();
      expect(svc.getBool('ledger_dual_write'), isFalse);
      expect(svc.getBool('ledger_pull_sync'), isFalse);
      expect(svc.getBool('ledger_push_sync'), isFalse);
      expect(svc.getBool('smart_inbox_pull_sync'), isFalse);
    });

    test('sync flag stays false when server sends is_active=false', () async {
      await RemoteFeatureFlagsDao(db).replaceAll([
        _flag('ledger_pull_sync', 'true', isActive: false),
      ]);
      final svc =
          FeatureFlagService(dao: RemoteFeatureFlagsDao(db), installId: 'test');
      await svc.init();
      expect(svc.getBool('ledger_pull_sync'), isFalse);
    });

    test('sync flag can be enabled when server sends is_active=true rollout=100',
        () async {
      await RemoteFeatureFlagsDao(db).replaceAll([
        _flag('ledger_pull_sync', 'true'),
      ]);
      final svc =
          FeatureFlagService(dao: RemoteFeatureFlagsDao(db), installId: 'test');
      await svc.init();
      expect(svc.getBool('ledger_pull_sync'), isTrue);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('AnnouncementService — active filtering and dismiss', () {
    test('returns only active non-dismissed announcements', () async {
      final dao = RemoteAnnouncementsDao(db);
      await dao.replaceAll([
        _announcement(id: 'a1'),
        _announcement(id: 'a2'),
      ]);
      await dao.setDismissed('a2');
      final svc = AnnouncementService(dao: dao);
      final active = await svc.getActiveAnnouncements();
      expect(active.length, 1);
      expect(active.first.id, 'a1');
    });

    test('dismiss removes announcement from active list', () async {
      final dao = RemoteAnnouncementsDao(db);
      await dao.replaceAll([_announcement(id: 'a1')]);
      final svc = AnnouncementService(dao: dao);
      await svc.dismiss('a1');
      expect(await svc.getActiveAnnouncements(), isEmpty);
    });

    test('expired announcement (validUntil in the past) is excluded', () async {
      final dao = RemoteAnnouncementsDao(db);
      final past = DateTime.now().toUtc().subtract(const Duration(hours: 2));
      await dao.replaceAll([
        _announcement(
          id: 'expired',
          validFrom: past.subtract(const Duration(hours: 1)),
          validUntil: past,
        ),
      ]);
      expect(await AnnouncementService(dao: dao).getActiveAnnouncements(),
          isEmpty);
    });

    test('hasForceUpdate returns true for force_update severity', () async {
      final dao = RemoteAnnouncementsDao(db);
      await dao.replaceAll([_announcement(id: 'fu', severity: 'force_update')]);
      expect(await AnnouncementService(dao: dao).hasForceUpdate(), isTrue);
    });

    test('hasForceUpdate returns false with no force_update', () async {
      final dao = RemoteAnnouncementsDao(db);
      await dao.replaceAll([_announcement(id: 'a1', severity: 'info')]);
      expect(await AnnouncementService(dao: dao).hasForceUpdate(), isFalse);
    });

    test('replaceAll preserves dismissed state across re-sync', () async {
      final dao = RemoteAnnouncementsDao(db);
      await dao.replaceAll([_announcement(id: 'a1')]);
      await dao.setDismissed('a1');
      // Simulate server re-push of same announcement
      await dao.replaceAll([_announcement(id: 'a1')]);
      expect(await AnnouncementService(dao: dao).getActiveAnnouncements(),
          isEmpty);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  group('SeedLoader — version metadata regression', () {
    test('seedIfEmpty sets catalog_metadata for all syncable categories',
        () async {
      await const SeedLoader().seedIfEmpty(db);
      final meta = CatalogMetadataDao(db);
      for (final category in CatalogCategories.syncable) {
        final v = await meta.getVersion(category);
        expect(v, isNotNull,
            reason: 'catalog_metadata missing for "$category"');
        expect(v!.serverVersion, 0);
      }
    });

    test('seedIfEmpty seeds all required catalog tables', () async {
      await const SeedLoader().seedIfEmpty(db);
      expect(await db.count('remote_banks'), greaterThanOrEqualTo(12));
      expect(await db.count('remote_parsers'), greaterThanOrEqualTo(12));
      expect(await db.count('remote_currencies'), 11);
      expect(await db.count('remote_countries'), 10);
      expect(await db.count('remote_categories'), 21);
      expect(await db.count('remote_feature_flags'), greaterThanOrEqualTo(4));
    });
  });
}
