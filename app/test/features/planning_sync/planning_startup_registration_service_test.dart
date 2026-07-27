import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';
import 'package:money_companion/features/planning_sync/services/planning_startup_registration_service.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('startup registers settings and custom categories exactly once',
      () async {
    final db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    addTearDown(db.close);
    await db.customStatement('''
      INSERT INTO categories(id,key,name_ar,icon,color,is_income,sort_order)
      VALUES ('custom-1','custom_hobby','هواية','star','#123456',0,100);
    ''');
    final queue = PlanningOutboxQueue(
      db: db,
      isSyncEnabled: (_) => true,
      getAuthUserId: () async => 'user-1',
    );
    final service = PlanningStartupRegistrationService(
      db: db,
      queue: queue,
      isEnabled: (_) => true,
    );

    await service.registerMissingRows();
    await service.registerMissingRows();

    final rows = await db.customSelect('''
      SELECT entity_type, COUNT(*) AS n FROM planning_sync_outbox
      WHERE entity_type IN ('settings','category')
      GROUP BY entity_type ORDER BY entity_type;
    ''').get();
    expect(rows, hasLength(2));
    expect(rows.every((row) => row.read<int>('n') == 1), isTrue);
  });
}
