import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/catalog/catalog_daos.dart';
import 'package:money_companion/data/catalog/seed_loader.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';

  @override
  Future<String?> readStoredKey() async => 'memory-key';
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

  tearDown(() async {
    await db.close();
  });

  test('SeedLoader seeds bundled catalog assets once', () async {
    const loader = SeedLoader();

    await loader.seedIfEmpty(db);

    expect(await db.count('remote_banks'), greaterThanOrEqualTo(12));
    expect(await db.count('remote_parsers'), greaterThanOrEqualTo(12));
    expect(await db.count('remote_currencies'), 11);
    expect(await db.count('remote_countries'), 10);
    expect(await db.count('remote_categories'), 21);

    final metadata = CatalogMetadataDao(db);
    for (final category in CatalogCategories.phase0) {
      final version = await metadata.getVersion(category);
      expect(version, isNotNull);
      expect(version!.serverVersion, 0);
      expect(version.localVersion, 0);
    }

    final banksBefore = await db.count('remote_banks');
    await loader.seedIfEmpty(db);
    expect(await db.count('remote_banks'), banksBefore);
  });
}
