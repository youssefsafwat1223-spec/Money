import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/features/coupons/coupons_providers.dart';
import '../../../tool/visual_parity/coupon_eligibility_readback.dart';
import '../../../tool/visual_parity/secondary_fixtures.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'coupon-readback-memory';
  @override
  Future<String?> readStoredKey() async => 'coupon-readback-memory';
}

Future<Map<String, Object>> snapshot(AppDatabase db) async {
  final tables = await db
      .customSelect(
          "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
      .get();
  return {
    for (final t in tables)
      t.read<String>('name'): (await db
              .customSelect(
                  'SELECT * FROM "${t.read<String>('name')}" ORDER BY rowid')
              .get())
          .map((r) => r.data)
          .toList()
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'actual five cached offers filter expired and other-country without writes',
      () async {
    final db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _Keys());
    final container = ProviderContainer(overrides: [
      appDatabaseProvider.overrideWithValue(db),
      ...visualParitySecondaryOverrides(mode: 'data')
    ]);
    try {
      final settings = container.read(userSettingsRepositoryProvider);
      await settings.saveSettings((await settings.getSettings())
          .copyWith(currency: 'EGP', country: 'EG'));
      await seedVisualParitySecondaryFixtures(container, db);
      final repository = container.read(transactionRepositoryProvider);
      final before = await snapshot(db);
      final result = await readVisualParityCouponEligibility(container);
      expect(result['cachedIds'],
          containsAll(['p-coupon-expired', 'p-coupon-country']));
      expect(result['cachedIds'], hasLength(5));
      expect(
          result['eligibleIds'],
          unorderedEquals([
            'p-coupon-talabat',
            'p-coupon-carrefour',
            'p-coupon-breadfast'
          ]));
      expect(result['country'], 'EG');
      expect(result['affiliateTracking'], false);
      expect(result['personalization'], false);
      expect((await settings.getSettings()).cloudProcessingEnabled, false);
      expect(await snapshot(db), before);
      expect(
          identical(container.read(transactionRepositoryProvider), repository),
          true);
    } finally {
      container.dispose();
      await db.close();
    }
  });
  test(
      'actual content gate off yields no eligible results without inventing offers',
      () async {
    final db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _Keys());
    final container = ProviderContainer(overrides: [
      appDatabaseProvider.overrideWithValue(db),
      ...visualParitySecondaryOverrides(mode: 'data'),
      couponsEnabledProvider.overrideWithValue(false)
    ]);
    try {
      await seedVisualParitySecondaryFixtures(container, db);
      final before = await snapshot(db);
      final result = await readVisualParityCouponEligibility(container);
      expect(result['cachedIds'], hasLength(5));
      expect(result['eligibleIds'], isEmpty);
      expect(result['contentEnabled'], false);
      expect(await snapshot(db), before);
    } finally {
      container.dispose();
      await db.close();
    }
  });
  test('file-backed parent rejected before catalog reads', () async {
    final dir = await Directory.systemTemp.createTemp('qirsh-coupon-readback-');
    final db = await AppDatabase.open(
        executor: NativeDatabase(File('${dir.path}/test.sqlite')),
        keyStore: _Keys());
    var reads = 0;
    final container = ProviderContainer(overrides: [
      appDatabaseProvider.overrideWithValue(db),
      cachedCouponsProvider.overrideWith((ref) {
        reads++;
        throw StateError('must_not_read_catalog');
      })
    ]);
    try {
      final before = await snapshot(db);
      await expectLater(
          readVisualParityCouponEligibility(container), throwsStateError);
      expect(reads, 0);
      expect(await snapshot(db), before);
    } finally {
      container.dispose();
      await db.close();
      await dir.delete(recursive: true);
    }
  });
}
