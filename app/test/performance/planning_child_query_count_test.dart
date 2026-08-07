// Phase-7 Batch-2-A (MALI-029) — query-count evidence for PlanningChildSync.
//
// Proves the batched parent/child/pending resolution makes a child pull page's
// SELECT count a function of distinct parent keys + chunks, not row count: 100
// and 1,000 goal-contribution rows that all reference a small set of goals
// resolve with the same handful of SELECTs.
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/sync/sync_cursor.dart';
import 'package:money_companion/features/planning_sync/services/planning_child_sync_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';

import 'perf_harness.dart';

class _GoalContribSource implements PlanningChildRemote {
  _GoalContribSource(this.rows);
  final List<Map<String, dynamic>> rows;

  @override
  Future<List<Map<String, dynamic>>> fetchRows(
    String table, {
    required SyncCursor after,
    int limit = 200,
  }) async {
    if (table != 'user_goal_contributions') return const [];
    final ordered = [...rows]..sort((a, b) {
        final t =
            (a['updated_at'] as String).compareTo(b['updated_at'] as String);
        return t != 0 ? t : (a['id'] as String).compareTo(b['id'] as String);
      });
    return ordered
        .where((row) {
          if (after.id.isEmpty) return true;
          final t = (row['updated_at'] as String).compareTo(after.updatedAt);
          return t > 0 ||
              (t == 0 && (row['id'] as String).compareTo(after.id) > 0);
        })
        .take(limit)
        .toList();
  }

  @override
  Future<Map<String, dynamic>> callRpc(String name, Map<String, dynamic> p) =>
      throw UnsupportedError(name);
  @override
  Future<Map<String, dynamic>?> findPlanLink(
          {required String userId,
          required String planId,
          required String transactionId}) async =>
      null;
  @override
  Future<Map<String, dynamic>> upsertPlanLink(Map<String, dynamic> row) =>
      throw UnsupportedError('upsertPlanLink');
  @override
  Future<void> tombstonePlanLink(String serverId) async {}
}

Future<void> _seedGoals(dynamic db, int count) async {
  const now = '2026-07-23T09:00:00.000Z';
  for (var i = 0; i < count; i++) {
    await db.customStatement('''
      INSERT INTO goals(id,name,target_amount,saved_amount,vault_skin,status,
        created_at,server_id,sync_status)
      VALUES ('goal-$i','G$i',100,0,'classic','active','$now',
        'server-goal-$i','synced');
    ''');
  }
}

List<Map<String, dynamic>> _contribs(int count, {required int goals}) {
  final base = DateTime.utc(2026, 7, 23, 10);
  return [
    for (var i = 0; i < count; i++)
      {
        'id': 'srv-gc-${i.toString().padLeft(5, '0')}',
        'local_id': 'loc-gc-${i.toString().padLeft(5, '0')}',
        'goal_id': 'server-goal-${i % goals}', // high parent-key repetition
        'amount': 5.0 + i,
        'created_at': base.toIso8601String(),
        'note': null,
        'updated_at': base.add(Duration(seconds: i)).toIso8601String(),
        'deleted_at': null,
      },
  ];
}

Future<int> _syncSelects(int count) async {
  final counting = await openCountingDb();
  try {
    await _seedGoals(counting.db, 4);
    final queue = PlanningOutboxQueue(
      db: counting.db,
      isSyncEnabled: (_) => true,
      getAuthUserId: () async => 'user-1',
    );
    final service = PlanningChildSyncService(
      db: counting.db,
      queue: queue,
      isEnabled: (entity) =>
          entity == PlanningOutboxQueue.goalContributionsEntityType,
      getAuthUserId: () async => 'user-1',
      remote: _GoalContribSource(_contribs(count, goals: 4)),
      pageSize: 5000,
    );
    counting.counter.reset();
    await service.sync();
    return counting.counter.selects;
  } finally {
    await counting.close();
  }
}

void main() {
  test('PlanningChildSync pull: SELECTs O(distinct parents + chunks)', () async {
    final at100 = await _syncSelects(100);
    final at1000 = await _syncSelects(1000);
    // Old path: _localId(parent) + _childLocalId(_localId) + _preservePending
    // = ~3 SELECTs per child row. New: parent prefetch + child index (server_id
    // + id) = a per-batch constant, flat except the extra chunk at 1,000 ids.
    expect(at100, lessThan(12));
    expect(at1000, lessThan(12));
    expect(at1000 - at100, lessThanOrEqualTo(4),
        reason: 'growth is O(chunks), not O(rows)');
  });
}
