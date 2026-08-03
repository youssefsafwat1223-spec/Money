import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/session/unsynced_inventory.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

// MALI-053n/011: the pre-sign-out inventory must detect every category of
// unsynced/local-only user data so sign-out never silently wipes it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  var localOnlyCards = 0;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    localOnlyCards = 0;
  });
  tearDown(() => db.close());

  UnsyncedInventoryService service() => UnsyncedInventoryService(
        db,
        localOnlyCardCount: () async => localOnlyCards,
      );

  test('a clean, fully-synced database reports nothing pending', () async {
    final inv = await service().collect();
    expect(inv.hasPendingUserData, isFalse);
    expect(inv.pendingUserDataCount, 0);
  });

  test('a pending ledger outbox row is detected as unsynced user data',
      () async {
    await db.customStatement(
      "INSERT INTO ledger_sync_outbox(id, transaction_id, operation, "
      "payload_json, created_at, updated_at) VALUES ('o1', 't1', 'create', "
      "'{}', '2026-01-01', '2026-01-01');",
    );
    final inv = await service().collect();
    expect(inv.ledgerOutbox, 1);
    expect(inv.hasPendingUserData, isTrue);
  });

  test('pending planning (parent/child) outbox rows are detected', () async {
    await db.customStatement(
      "INSERT INTO planning_sync_outbox(id, entity_type, entity_id, operation, "
      "payload_json, created_at, updated_at) VALUES ('p1', 'goal_contribution', "
      "'gc1', 'create', '{}', '2026-01-01', '2026-01-01');",
    );
    final inv = await service().collect();
    expect(inv.planningOutbox, 1);
    expect(inv.hasPendingUserData, isTrue);
  });

  test('a pending smart-inbox item is detected', () async {
    await db.customStatement(
      "INSERT INTO smart_inbox_items(id, server_id, type, title, "
      "server_created_at, synced_at, created_at, updated_at, pending_sync) "
      "VALUES ('s1', 'srv1', 'nudge', 'T', '2026-01-01', '2026-01-01', "
      "'2026-01-01', '2026-01-01', 1);",
    );
    final inv = await service().collect();
    expect(inv.smartInboxPending, 1);
    expect(inv.hasPendingUserData, isTrue);
  });

  test('local-only (cloud-unsupported) cards are counted as unsynced', () async {
    localOnlyCards = 3;
    final inv = await service().collect();
    expect(inv.localOnlyCards, 3);
    expect(inv.hasPendingUserData, isTrue);
  });
}
