import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/session/unsynced_inventory.dart';
import 'package:money_companion/core/sync/sync_health.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import '../../harness/seed_test_account.dart';

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
    await seedTestAccount(db);
    localOnlyCards = 0;
  });
  tearDown(() => db.close());

  UnsyncedInventoryService service() => UnsyncedInventoryService(
        db,
        localOnlyCardCount: () async => localOnlyCards,
      );

  /// Audit H-3 changed the definition of "pending": an empty outbox is not
  /// proof of remote persistence. A fresh database carries the
  /// migration-seeded default account, which has no `server_id` and no outbox
  /// entry — the reconcile service's docstring names it explicitly as a row it
  /// exists to back-fill, and `hasUnsyncedLocalData()` already counted it with
  /// this same predicate. So it is genuinely unproven until backfilled.
  Future<void> markAllAccountsSynced() => db.customStatement(
        "UPDATE accounts SET server_id = 'srv-' || id, "
        "synced_at = '2026-01-01T00:00:00Z', sync_status = 'synced';",
      );

  test('a database whose rows are all PROVEN synced reports nothing pending',
      () async {
    await markAllAccountsSynced();
    final inv = await service().collect();
    expect(inv.hasPendingUserData, isFalse);
    expect(inv.pendingUserDataCount, 0);
  });

  test('the seeded default account is unproven until it is backfilled',
      () async {
    // Pre-H-3 this reported 0 and sign-out wiped without a word.
    final before = await service().collect();
    expect(before.unprovenFinancialRows, greaterThan(0));
    expect(before.hasPendingUserData, isTrue,
        reason: 'a row with no server_id and no outbox entry is not proven '
            'persisted, and sign-out must not destroy it silently');

    await markAllAccountsSynced();
    final after = await service().collect();
    expect(after.unprovenFinancialRows, 0);
    expect(after.hasPendingUserData, isFalse);
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

  test('local-only (cloud-unsupported) cards are counted as unsynced',
      () async {
    localOnlyCards = 3;
    final inv = await service().collect();
    expect(inv.localOnlyCards, 3);
    expect(inv.hasPendingUserData, isTrue);
  });

  group('server-backed pending rows with NO outbox row (bypass writers)', () {
    Future<void> pendingTx(String id,
            {String status = 'confirmed', String sync = 'pending'}) =>
        db.customStatement('''
      INSERT INTO transactions(id, amount, currency, type, source, occurred_at,
        raw_message, parse_confidence, status, created_at, updated_at,
        server_id, sync_status)
      VALUES ('$id', 1, 'SAR', 'payment', 'bank', '2026-06-01T00:00:00Z', '',
        0.9, '$status', '2026-06-01T00:00:00Z', '2026-06-01T00:00:00Z',
        'srv-$id', '$sync');
    ''');

    test('counted for sign-out; synced and outbox-covered rows are not',
        () async {
      await markAllAccountsSynced();
      expect((await service().collect()).hasPendingUserData, isFalse);
      await pendingTx('t-edit');
      await pendingTx('t-synced', sync: 'synced');
      await pendingTx('t-queued');
      await db.customStatement(
        "INSERT INTO ledger_sync_outbox(id, transaction_id, operation, "
        "payload_json, created_at, updated_at) VALUES ('o1', 't-queued', "
        "'update', '{}', '2026-01-01', '2026-01-01');",
      );
      final inv = await service().collect();
      expect(inv.unprovenFinancialRows, 1);
      expect(inv.hasPendingUserData, isTrue);
    });

    test('a pending tombstone (ignored tx / deleted parent) is still counted',
        () async {
      await markAllAccountsSynced();
      await pendingTx('t-gone', status: 'ignored');
      await db.customStatement("UPDATE accounts SET sync_status = 'pending', "
          "deleted_at = '2026-06-01T00:00:00Z';");
      final inv = await service().collect();
      expect(inv.unprovenFinancialRows, greaterThanOrEqualTo(2));
      // The status variant (excludeIgnored) hides only never-synced ignored
      // rows; a server-backed pending delete is still unproven.
      expect(await countUnprovenFinancialRows(db, excludeIgnored: true),
          inv.unprovenFinancialRows);
    });

    test('covers parent tables: goals/budgets/plans/subscriptions/settings',
        () async {
      await markAllAccountsSynced();
      await db.customStatement('''
        INSERT INTO goals(id, name, target_amount, saved_amount, currency,
          target_amount_minor, saved_amount_minor,
          last_notified_saved_amount_minor, vault_skin, status, created_at,
          server_id, sync_status)
        VALUES ('goal', 'G', 100, 0, 'SAR', 10000, 0, 0, 'classic', 'active',
          '2026-07-01T00:00:00Z', 'srv-goal', 'pending');
      ''');
      await db.customStatement(
          "UPDATE user_settings SET server_id = 'srv-set', sync_status = 'pending';");
      expect((await service().collect()).unprovenFinancialRows, 2);
    });

    test('SyncHealth.queueCounts (SyncStatus) sees them: not allSynced',
        () async {
      await markAllAccountsSynced();
      await pendingTx('t-edit');
      final counts = await SyncHealth.queueCounts(db);
      expect(counts.unprovenLocalRows, 1);
    });
  });
}
