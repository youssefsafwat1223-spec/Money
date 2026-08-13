import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/sync/conflict_policy.dart';
import 'package:money_companion/core/sync/conflict_resolver.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';

// MALI-026 (Phase-9K) — a DELETE conflict (a stale delete that lost to a newer
// accepted update) must be SURFACED and RESOLVABLE. The local row is soft-deleted
// (goals: deleted_at; transactions: status='ignored') yet in sync_status='conflict':
//   • it must appear in listConflicts (the old deleted_at filter hid it),
//   • keep-mine must re-enqueue a rebased DELETE (not an update that resurrects it),
//   • keep-theirs marks synced so the next pull revives the server's version.

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late List<String> reEnqueuedUpdate;
  late UniversalConflictResolver resolver;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    reEnqueuedUpdate = <String>[];
    resolver = UniversalConflictResolver(
      db: db,
      reEnqueue: {
        for (final p in interactiveConflictPolicies)
          p.entityType: (id) async =>
              reEnqueuedUpdate.add('${p.entityType}/$id'),
      },
      // The server has moved to revision 7 — keep-mine must rebase onto it.
      baseFetcher: (table, serverId) async =>
          const ConflictBase(updatedAt: 'current-server-ts', revision: 7),
    );
  });
  tearDown(() => db.close());

  Future<void> seedDeletedGoal(String id) async {
    await db.customStatement(
      "INSERT INTO goals(id, name, currency, target_amount, target_amount_minor, "
      "saved_amount, saved_amount_minor, last_notified_saved_amount_minor, "
      "vault_skin, status, created_at, server_id, server_updated_at, "
      "server_revision, sync_status, deleted_at) VALUES "
      "('$id', 'Travel', 'SAR', 5000, 500000, 300, 30000, 0, 'classic', "
      "'archived', '2026-07-01', 'srv-$id', 'base-ts', 5, 'conflict', "
      "'2026-08-02T00:00:00.000Z');",
    );
    await backfillNonPlanningMoneyV30(db);
    await db.customStatement(
      "INSERT INTO planning_sync_outbox(id, entity_type, entity_id, operation, "
      "payload_json, created_at, updated_at) VALUES "
      "('ob-$id', 'goal', '$id', 'update', '{}', '2026-07-01', '2026-07-01');",
    );
  }

  Future<void> seedIgnoredTransaction(String id) async {
    await db.customStatement(
      "INSERT INTO transactions(id, amount, currency, type, source, occurred_at, "
      "raw_message, parse_confidence, status, created_at, updated_at, server_id, "
      "server_updated_at, server_revision, sync_status) VALUES "
      "('$id', 42.0, 'SAR', 'payment', 'bank', '2026-07-01', 'msg', 0.9, "
      "'ignored', '2026-07-01', '2026-07-01', 'srv-$id', 'base-ts', 5, 'conflict');",
    );
    await backfillNonPlanningMoneyV30(db);
    await db.customStatement(
      "INSERT INTO ledger_sync_outbox(id, transaction_id, operation, payload_json, "
      "created_at, updated_at) VALUES ('ob-$id', '$id', 'update', '{}', "
      "'2026-07-01', '2026-07-01');",
    );
  }

  Future<String?> statusOf(String table, String id) async => (await db
          .customSelect("SELECT sync_status FROM $table WHERE id='$id';")
          .getSingle())
      .readNullable<String>('sync_status');

  Future<Map<String, String?>> outboxRow(String table, String where) async {
    final row = await db
        .customSelect(
            'SELECT operation, payload_json FROM $table WHERE $where;')
        .getSingleOrNull();
    return {
      'operation': row?.readNullable<String>('operation'),
      'payload': row?.readNullable<String>('payload_json'),
    };
  }

  test('a locally-deleted goal in conflict IS surfaced by listConflicts',
      () async {
    await seedDeletedGoal('g1');
    final conflicts = await resolver.listConflicts();
    expect(conflicts.map((c) => c.entityType), contains(ConflictEntities.goal));
    expect(conflicts.single.localId, 'g1');
  });

  test(
      'keep-mine on a deleted goal re-enqueues a REBASED delete (not an '
      'update), leaving the row pending', () async {
    await seedDeletedGoal('g1');
    await resolver.resolveKeepLocal(ConflictEntities.goal, 'g1');

    final ob = await outboxRow('planning_sync_outbox', "entity_id='g1'");
    expect(ob['operation'], 'delete',
        reason: 'keep-mine re-applies the delete');
    expect(ob['payload'], contains('"server_revision":7'),
        reason: 'rebased onto the current server revision so the CAS wins');
    expect(await statusOf('goals', 'g1'), 'pending');
    expect(reEnqueuedUpdate, isEmpty,
        reason: 'the typed update re-enqueue (which would resurrect it) must '
            'NOT run for a deleted row');
  });

  test(
      'keep-mine on an ignored (deleted) transaction re-enqueues a delete into '
      'the ledger outbox', () async {
    await seedIgnoredTransaction('tx1');
    await resolver.resolveKeepLocal(ConflictEntities.transaction, 'tx1');

    final ob = await outboxRow('ledger_sync_outbox', "transaction_id='tx1'");
    expect(ob['operation'], 'delete');
    expect(ob['payload'], contains('"server_revision":7'));
    expect(ob['payload'], contains('srv-tx1'));
    expect(reEnqueuedUpdate, isEmpty);
  });

  test(
      'keep-theirs on a deleted goal marks synced + drops the outbox (the next '
      'pull revives the server version)', () async {
    await seedDeletedGoal('g1');
    await resolver.resolveKeepRemote(ConflictEntities.goal, 'g1');
    expect(await statusOf('goals', 'g1'), 'synced');
    final ob = await outboxRow('planning_sync_outbox', "entity_id='g1'");
    expect(ob['operation'], isNull, reason: 'outbox row dropped');
  });

  test(
      'regression: keep-mine on a NON-deleted goal still re-enqueues an UPDATE',
      () async {
    // Same seed but alive (no deleted_at, status active).
    await db.customStatement(
      "INSERT INTO goals(id, name, currency, target_amount, target_amount_minor, "
      "saved_amount, saved_amount_minor, last_notified_saved_amount_minor, "
      "vault_skin, status, created_at, server_id, server_updated_at, "
      "server_revision, sync_status) VALUES "
      "('g2', 'Live', 'SAR', 5000, 500000, 300, 30000, 0, 'classic', 'active', "
      "'2026-07-01', 'srv-g2', 'base-ts', 5, 'conflict');",
    );
    await backfillNonPlanningMoneyV30(db);

    await resolver.resolveKeepLocal(ConflictEntities.goal, 'g2');
    expect(reEnqueuedUpdate, ['goal/g2']);
    final ob = await outboxRow('planning_sync_outbox', "entity_id='g2'");
    expect(ob['operation'], isNot('delete'));
  });
}
