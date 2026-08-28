// MALI-026 (Phase-9B) — exercises the REAL canonical goal-contribution PUSH branch
// of PlanningChildSyncService against the migration-0078 response shape:
//   * canonical mode reads goal.saved_amount_text (exact decimal String) and writes
//     the exact `saved_amount_minor` authority via Money — NEVER the raw JSON number;
//   * a missing saved_amount_text in canonical mode fails CLOSED (no numeric
//     fallback, the local money authority is left untouched).
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';
import 'package:money_companion/data/db/planning_cutover.dart';
import 'package:money_companion/data/sync/sync_cursor.dart';
import 'package:money_companion/domain/entities/goal_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/planning_sync/services/planning_child_sync_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

/// Fake remote whose add_goal_contribution returns the 0078 (post-fix) goal shape.
/// [includeSavedAmountText] toggles the fail-closed case (server omits the field).
/// The raw `saved_amount` JSON number is deliberately WRONG (99.99) so any assertion
/// that the exact `saved_amount_text` ("12.345") drove the write is unambiguous.
class _CanonicalFakeRemote implements PlanningChildRemote {
  _CanonicalFakeRemote({this.includeSavedAmountText = true});
  final bool includeSavedAmountText;

  @override
  Future<Map<String, dynamic>> callRpc(
    String name,
    Map<String, dynamic> params,
  ) async {
    const now = '2026-07-23T10:00:00.000Z';
    if (name != 'add_goal_contribution') throw UnsupportedError(name);
    final contribution = <String, dynamic>{
      'id': 'server-gc-${params['p_local_id']}',
      'local_id': params['p_local_id'],
      'goal_id': params['p_goal_id'],
      'amount': params['p_amount'],
      'created_at': params['p_created_at'],
      'note': params['p_note'],
      'updated_at': now,
      'deleted_at': null,
    };
    final goal = <String, dynamic>{
      'id': params['p_goal_id'],
      'saved_amount': 99.99, // WRONG on purpose — must never be consumed
      'currency': 'KWD',
      'updated_at': now,
      if (includeSavedAmountText) 'saved_amount_text': '12.345',
    };
    return {'contribution': contribution, 'goal': goal};
  }

  // Pull is a no-op in this push-focused test.
  @override
  Future<List<Map<String, dynamic>>> fetchRows(
    String table, {
    required SyncCursor after,
    int limit = 200,
  }) async =>
      const [];

  @override
  Future<Map<String, dynamic>?> findPlanLink({
    required String userId,
    required String planId,
    required String transactionId,
  }) async =>
      throw UnsupportedError('findPlanLink');

  @override
  Future<void> tombstonePlanLink(String serverId) async =>
      throw UnsupportedError('tombstonePlanLink');

  @override
  Future<Map<String, dynamic>> upsertPlanLink(Map<String, dynamic> row) async =>
      throw UnsupportedError('upsertPlanLink');
}

Future<AppDatabase> _openDb() => AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );

bool _onlyContributions(String type) =>
    type == PlanningOutboxQueue.goalContributionsEntityType;

PlanningOutboxQueue _queue(AppDatabase db) => PlanningOutboxQueue(
      db: db,
      isSyncEnabled: _onlyContributions,
      getAuthUserId: () async => 'user-1',
    );

PlanningChildSyncService _canonicalService(
  AppDatabase db,
  PlanningOutboxQueue queue,
  _CanonicalFakeRemote remote,
) =>
    PlanningChildSyncService(
      db: db,
      queue: queue,
      isEnabled: _onlyContributions,
      getAuthUserId: () async => 'user-1',
      remote: remote,
      coordinator:
          const FixedPlanningCutoverCoordinator(PlanningCutoverState.canonical),
    
      // C-3: covers pull MECHANICS; consent is asserted in
      // financial_pull_consent_test.dart.
      mayEgress: () async => true,
    );

/// Seed a canonical KWD (3dp) goal + a queued contribution for it.
Future<void> _seedGoalAndContribution(AppDatabase db) async {
  const now = '2026-07-23T09:00:00.000Z';
  await db.customStatement('''
    INSERT INTO goals(id,name,target_amount,saved_amount,currency,
      target_amount_minor,saved_amount_minor,last_notified_saved_amount_minor,
      vault_skin,status,created_at,server_id,sync_status)
    VALUES ('goal-1','هدف',100,0,'KWD',100000,0,0,'classic','active',
      '$now','server-goal-1','synced');
  ''');
  await db.customStatement('''
    INSERT INTO goal_contributions(id,goal_id,amount,amount_minor,created_at)
    VALUES ('gc-1','goal-1',12.345,12345,'$now');
  ''');
  await backfillNonPlanningMoneyV30(db);
}

Future<void> _enqueue(PlanningOutboxQueue queue) => queue.enqueueGoalContribution(
      PlanningSyncOperation.create,
      GoalContributionEntity(
        id: 'gc-1',
        goalId: 'goal-1',
        amountMoney: Money.parse('12.345', 'KWD'),
        createdAt: DateTime.utc(2026, 7, 23, 9),
      ),
    );

Future<({int minor, double real})> _readGoal(AppDatabase db) async {
  final row = await db
      .customSelect(
          "SELECT saved_amount, saved_amount_minor FROM goals WHERE id='goal-1';")
      .getSingle();
  return (
    minor: row.read<int>('saved_amount_minor'),
    real: row.read<double>('saved_amount'),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'canonical push decodes goal.saved_amount_text EXACTLY (minor authority), '
      'never the raw saved_amount number', () async {
    final db = await _openDb();
    addTearDown(db.close);
    await _seedGoalAndContribution(db);
    final queue = _queue(db);
    await _enqueue(queue);
    final remote = _CanonicalFakeRemote(includeSavedAmountText: true);

    await _canonicalService(db, queue, remote).sync();

    // Outbox drained (push succeeded).
    final pending = await db
        .customSelect('SELECT COUNT(*) AS n FROM planning_sync_outbox;')
        .getSingle();
    expect(pending.read<int>('n'), 0);

    // Exact KWD 3dp: "12.345" -> 12345 minor. The wrong number (99.99 -> 99990)
    // would appear here if the raw saved_amount had been consumed. It is not.
    final goal = await _readGoal(db);
    expect(goal.minor, 12345);
    expect(goal.real, closeTo(12.345, 1e-9));
  });

  test('canonical push FAILS CLOSED when saved_amount_text is missing '
      '(no numeric fallback to the raw saved_amount)', () async {
    final db = await _openDb();
    addTearDown(db.close);
    await _seedGoalAndContribution(db);
    final queue = _queue(db);
    await _enqueue(queue);
    final remote = _CanonicalFakeRemote(includeSavedAmountText: false);

    // sync() swallows the per-item error (marks it failed); it must NOT throw the
    // whole run, and it must NOT corrupt the local money authority.
    await _canonicalService(db, queue, remote).sync();

    // The goal's exact authority is untouched — no 99.99 leaked in via the number.
    final goal = await _readGoal(db);
    expect(goal.minor, 0);
    expect(goal.real, 0);

    // The item did not drain to success (it failed closed and remains for retry).
    final pending = await db
        .customSelect('SELECT COUNT(*) AS n FROM planning_sync_outbox;')
        .getSingle();
    expect(pending.read<int>('n'), greaterThan(0));
  });
}
