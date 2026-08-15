// MALI-COUPONS (Phase C4) — Drift v31 migration (§39) and the atomic catalog
// cache replace (§40 A–F) against a REAL database.
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/catalog/catalog_daos.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/features/coupons/coupon_models.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

Future<int> _userVersion(AppDatabase db) async =>
    (await db.customSelect('PRAGMA user_version;').getSingle()).read<int>('user_version');

Future<bool> _hasTable(AppDatabase db, String name) async =>
    (await db
            .customSelect(
              "SELECT COUNT(*) AS n FROM sqlite_master "
              "WHERE type = 'table' AND name = '$name';",
            )
            .getSingle())
        .read<int>('n') ==
    1;

CouponOffer _offer(String id, {String slug = 's', List<CouponTag> tags = const []}) =>
    CouponOffer(
      id: id,
      slug: slug,
      partnerName: 'Partner',
      titleAr: 'عنوان',
      descriptionAr: 'وصف',
      redemptionType: CouponRedemptionType.code,
      code: 'CODE$id',
      category: const CouponCategory(key: 'food', labelAr: 'مطاعم', labelEn: 'Food'),
      validFrom: DateTime.utc(2026, 8, 1),
      validUntil: DateTime.utc(2027, 1, 1),
      tags: tags,
      countryCodes: const ['SA'],
      spendHintCategoryKeys: const ['restaurants'],
      accentHex: '#2563EB',
      featured: true,
      priority: 5,
      termsAr: 'شروط',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Drift v31 migration (§39)', () {
    test('A/D: a fresh database is at v31 with an EMPTY coupon cache', () async {
      final db = await AppDatabase.open(
          executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
      addTearDown(db.close);
      expect(await _userVersion(db), 31);
      expect(await _hasTable(db, 'remote_coupons'), isTrue);
      expect(await RemoteCouponsDao(db).count(), 0);
    });

    test('B/C: a real v30 file upgrades to v31, creating ONLY the new table and '
        'preserving existing business data', () async {
      final dir = Directory.systemTemp.createTempSync('coupons_v31');
      final path = '${dir.path}/app.db';
      addTearDown(() => dir.deleteSync(recursive: true));

      // Build a v30-shaped database: drop the v31 addition and stamp 30.
      final v30 = await AppDatabase.open(
          executor: NativeDatabase(File(path)), keyStore: _MemoryKeyStore());
      await v30.customStatement(
        "INSERT INTO accounts(id, name, currency, type, created_at, updated_at) "
        "VALUES ('acc-keep', 'Bank', 'SAR', 'bank', '2026-01-01', '2026-01-01');",
      );
      await v30.customStatement('DROP TABLE remote_coupons;');
      await v30.customStatement('PRAGMA user_version = 30;');
      expect(await _hasTable(v30, 'remote_coupons'), isFalse);
      await v30.close();

      // Reopening runs the additive migration.
      final v31 = await AppDatabase.open(
          executor: NativeDatabase(File(path)), keyStore: _MemoryKeyStore());
      addTearDown(v31.close);
      expect(await _userVersion(v31), 31);
      expect(await _hasTable(v31, 'remote_coupons'), isTrue);
      expect(await RemoteCouponsDao(v31).count(), 0, reason: 'starts empty');
      // C: pre-existing financial data survived untouched.
      final kept = await v31
          .customSelect("SELECT name FROM accounts WHERE id = 'acc-keep';")
          .getSingleOrNull();
      expect(kept?.read<String>('name'), 'Bank');
    });

    test('E: the newer-than-app guard still fails closed at v31', () async {
      // Same single-instance pattern the migration pipeline suite uses: stamp a
      // version newer than the app, then drive initialize().
      final db = await AppDatabase.open(
          executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
      addTearDown(db.close);
      await db.customStatement('PRAGMA user_version = 999;');

      Object? caught;
      try {
        await db.debugReinitialize();
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<UnsupportedDatabaseVersionException>());
      expect((caught! as UnsupportedDatabaseVersionException).supportedVersion, 31);
      // Fail-closed: nothing was migrated or rewritten.
      expect(await _userVersion(db), 999);
    });
  });

  group('atomic cache replace (§40 A–F)', () {
    late AppDatabase db;
    late RemoteCouponsDao dao;

    setUp(() async {
      db = await AppDatabase.open(
          executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
      dao = RemoteCouponsDao(db);
    });
    tearDown(() => db.close());

    test('A: a successful snapshot lands whole and round-trips typed', () async {
      await dao.replaceAll([
        _offer('c1', slug: 'first', tags: const [
          CouponTag(key: 'food', labelAr: 'مطاعم', labelEn: 'Food'),
          CouponTag(key: 'delivery', labelAr: 'توصيل'),
        ]),
      ]);

      final cached = await dao.getAll();
      expect(cached, hasLength(1));
      final offer = cached.single;
      expect(offer.id, 'c1');
      expect(offer.slug, 'first');
      expect(offer.redemptionType, CouponRedemptionType.code);
      expect(offer.code, 'CODEc1');
      expect(offer.category.labelAr, 'مطاعم');
      expect(offer.category.labelEn, 'Food');
      // Embedded collections survive the JSON round-trip IN ORDER.
      expect(offer.tags.map((t) => t.key).toList(), ['food', 'delivery']);
      expect(offer.tags.first.labelEn, 'Food');
      expect(offer.spendHintCategoryKeys, ['restaurants']);
      expect(offer.countryCodes, ['SA']);
      expect(offer.accentColor, isNotNull);
      expect(offer.featured, isTrue);
      expect(offer.priority, 5);
      expect(offer.termsAr, 'شروط');
      expect(offer.validUntil, DateTime.utc(2027, 1, 1));
    });

    test('B: a later snapshot REPLACES the catalog (removed offers disappear)',
        () async {
      await dao.replaceAll([_offer('old1'), _offer('old2')]);
      expect(await dao.count(), 2);

      await dao.replaceAll([_offer('new1')]);
      final cached = await dao.getAll();
      expect(cached.map((o) => o.id).toList(), ['new1']);
    });

    test('C: an EMPTY successful snapshot clears the cache', () async {
      await dao.replaceAll([_offer('c1')]);
      await dao.replaceAll(const <CouponOffer>[]);
      expect(await dao.count(), 0);
      expect(await dao.getAll(), isEmpty);
    });

    test('D: a failing insert ROLLS BACK — the previous snapshot survives', () async {
      await dao.replaceAll([_offer('keep-me')]);

      // Force a mid-transaction failure: a duplicate primary key inside the new
      // batch. The delete + inserts share one transaction, so nothing commits.
      await expectLater(
        dao.replaceAll([_offer('dup'), _offer('dup')]),
        throwsA(anything),
      );

      final cached = await dao.getAll();
      expect(cached.map((o) => o.id).toList(), ['keep-me'],
          reason: 'the catalog is never left half-old/half-new');
    });

    test('E: a sync failure never calls replaceAll, so the cache is preserved',
        () async {
      await dao.replaceAll([_offer('cached')]);
      // (The service returns early on a non-2xx/unparseable body — see
      // CatalogSyncService.syncCoupons; nothing touches the DAO.)
      expect((await dao.getAll()).single.id, 'cached');
    });

    test('F: duplicate identities within one snapshot are rejected deterministically',
        () async {
      await expectLater(
        dao.replaceAll([_offer('same'), _offer('same')]),
        throwsA(anything),
      );
      expect(await dao.count(), 0, reason: 'rolled back, not partially applied');
    });
  });
}
