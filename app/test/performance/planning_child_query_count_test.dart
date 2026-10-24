// Phase-7 Batch-2-A (MALI-029) — query-count evidence for PlanningChildSync.
//
// Proves the batched parent/child/pending resolution makes a child pull page's
// SELECT count a function of distinct parent keys + chunks, not row count: 100
// and 1,000 goal-contribution rows that all reference a small set of goals
// resolve with the same handful of SELECTs.
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/sync/exact_transport_capability.dart';
import 'package:money_companion/data/sync/sync_cursor.dart';
import 'package:money_companion/features/planning_sync/services/planning_child_sync_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';

import '../features/capture/ledger_admission_fixture.dart';

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
      INSERT INTO goals(id,name,currency,target_amount,target_amount_minor,
        saved_amount,saved_amount_minor,last_notified_saved_amount_minor,
        vault_skin,status,created_at,server_id,sync_status)
      VALUES ('goal-$i','G$i','SAR',100,10000,0,0,0,'classic','active','$now',
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
        'amount_text': (5+i).toStringAsFixed(2),
        'created_at': base.toIso8601String(),
        'note': null,
        'updated_at': base.add(Duration(seconds: i)).toIso8601String(),
        'deleted_at': null,
      },
  ];
}

Future<int> _syncSelects(int count) async {
  final probe=LedgerDatabaseProbe();var selects=0;
  probe.before=(sql)async{if(sql.trimLeft().toUpperCase().startsWith('SELECT'))selects++;};
  final admission=await LedgerAdmissionFixture.open('user-1',probe);
  final db=admission.database;
  try {
    await _seedGoals(db, 4);
    final queue = PlanningOutboxQueue(
      db: db,
      isSyncEnabled: (_) => true,
      getAuthUserId: () async => 'user-1',
    );
    final service = PlanningChildSyncService(
      db: db,
      queue: queue,
      isEnabled: (entity) =>
          entity == PlanningOutboxQueue.goalContributionsEntityType,
      isPullEnabled: (entity) =>
          entity == PlanningOutboxQueue.goalContributionsEntityType,
      getAuthUserId: () async => 'user-1',
      remote: _GoalContribSource(_contribs(count, goals: 4)),
      pageSize: 5000,
      pullCapability: () => ExactTransportCapability.verifiedExact,
    
      // C-3: covers pull MECHANICS; consent is asserted in
      // financial_pull_consent_test.dart.
      mayEgress: () async => true,
    );
    selects=0;
    await service.sync();
    final measured=selects;
    expect((await db.customSelect('SELECT COUNT(*) AS n FROM goal_contributions;').getSingle()).read<int>('n'),count);
    return measured;
  } finally {
    await admission.finish();
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
