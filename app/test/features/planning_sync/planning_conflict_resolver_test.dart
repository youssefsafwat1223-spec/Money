import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_bill_repository.dart';
import 'package:money_companion/data/repositories/drift_budget_repository.dart';
import 'package:money_companion/data/repositories/drift_goal_repository.dart';
import 'package:money_companion/data/repositories/drift_plan_repository.dart';
import 'package:money_companion/domain/entities/goal_entity.dart';
import 'package:money_companion/features/planning_sync/services/planning_conflict_resolver.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';
import 'package:money_companion/features/planning_sync/services/planning_push_service.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

// The resolver only calls fetchServerUpdatedAt on the sink (keep-local path).
class _FakeSink implements PlanningRemoteSink {
  String? current;
  @override
  Future<String?> fetchServerUpdatedAt(String table, String serverId) async =>
      current;
  @override
  Future<Map<String, dynamic>> upsert(String t, Map<String, dynamic> r) async =>
      throw UnimplementedError();
  @override
  Future<Map<String, dynamic>> updateByServerId(
          String t, String s, Map<String, dynamic> r) async =>
      throw UnimplementedError();
  @override
  Future<Map<String, dynamic>?> findByLocalId(
          String t, String u, String l) async =>
      null;
  @override
  Future<void> tombstone(String t, String s) async {}
}

GoalEntity _goal(String id) => GoalEntity(
      id: id,
      name: 'Travel',
      targetAmount: 5000,
      savedAmount: 300,
      vaultSkin: 'classic',
      status: 'active',
      createdAt: DateTime.utc(2026, 7, 1),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late PlanningOutboxQueue queue;
  late PlanningConflictResolver resolver;
  late _FakeSink sink;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    queue = PlanningOutboxQueue(
      db: db,
      isSyncEnabled: (_) => true,
      getAuthUserId: () async => 'user-1',
    );
    sink = _FakeSink();
    resolver = PlanningConflictResolver(
      db: db,
      queue: queue,
      budgets: DriftBudgetRepository(db, outboxQueue: queue),
      goals: DriftGoalRepository(db, outboxQueue: queue),
      bills: DriftBillRepository(db, outboxQueue: queue),
      plans: DriftPlanRepository(db, outboxQueue: queue),
      remoteSink: sink,
    );
  });

  tearDown(() => db.close());

  // Puts goal g1 into the stuck conflict state (synced base, then conflict).
  Future<void> seedConflictedGoal() async {
    await DriftGoalRepository(db, outboxQueue: queue).save(_goal('g1'));
    await db.customStatement(
      "UPDATE goals SET server_id = 'srv-g1', "
      "server_updated_at = 'base-ts', sync_status = 'conflict' WHERE id = 'g1';",
    );
    await db.customStatement('DELETE FROM planning_sync_outbox;');
  }

  Future<String?> status() async => (await db
          .customSelect("SELECT sync_status FROM goals WHERE id='g1';")
          .getSingle())
      .readNullable<String>('sync_status');

  Future<int> outboxCount() async => (await db
          .customSelect('SELECT COUNT(*) AS n FROM planning_sync_outbox;')
          .getSingle())
      .read<int>('n');

  test('listConflicts surfaces conflicted planning rows', () async {
    await seedConflictedGoal();
    final conflicts = await resolver.listConflicts();
    expect(conflicts, hasLength(1));
    expect(conflicts.single.entityType, PlanningOutboxQueue.goalsEntityType);
    expect(conflicts.single.localId, 'g1');
    expect(conflicts.single.label, 'Travel');
  });

  test('keep-remote marks synced and drops the queued local change', () async {
    await seedConflictedGoal();
    await resolver.resolveKeepRemote(PlanningOutboxQueue.goalsEntityType, 'g1');
    expect(await status(), 'synced'); // next pull applies the remote row
    expect(await outboxCount(), 0);
    expect(await resolver.listConflicts(), isEmpty);
  });

  test('keep-local refreshes the base + re-enqueues so the next push wins',
      () async {
    await seedConflictedGoal();
    sink.current = 'current-server-ts'; // the current remote version

    await resolver.resolveKeepLocal(PlanningOutboxQueue.goalsEntityType, 'g1');

    // Base refreshed to the current server version → next push's guard passes.
    final base = (await db
        .customSelect(
            "SELECT server_updated_at, sync_status FROM goals WHERE id='g1';")
        .getSingle());
    expect(base.readNullable<String>('server_updated_at'), 'current-server-ts');
    expect(base.readNullable<String>('sync_status'), 'pending');
    // A fresh update outbox item was queued for this goal.
    final items = await db
        .customSelect(
          "SELECT entity_id, operation FROM planning_sync_outbox "
          "WHERE entity_type = '${PlanningOutboxQueue.goalsEntityType}';",
        )
        .get();
    expect(items, hasLength(1));
    expect(items.single.read<String>('entity_id'), 'g1');
    expect(await resolver.listConflicts(), isEmpty);
  });
}
