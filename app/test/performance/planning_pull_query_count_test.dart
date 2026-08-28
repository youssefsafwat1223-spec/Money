// Phase-7 Batch-2-A (MALI-029) — query-count evidence for PlanningPullService.
//
// Proves that after batching, the SELECT count for a subscriptions page (which
// resolves a merchant per row) and a budgets page (which resolves a category per
// row) is a function of DISTINCT keys + chunks, not of row count: 100 rows and
// 1,000 rows sharing a small key set resolve with the same handful of SELECTs.
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/sync/sync_cursor.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';
import 'package:money_companion/features/planning_sync/services/planning_pull_service.dart';

import 'perf_harness.dart';

class _FakePlanningSource implements PlanningRemoteSource {
  _FakePlanningSource(this.byTable);
  final Map<String, List<Map<String, dynamic>>> byTable;

  @override
  Future<List<Map<String, dynamic>>> fetchRows(
    String table, {
    required SyncCursor after,
    int limit = 200,
  }) async {
    final rows = [...?byTable[table]]..sort((a, b) {
        final t =
            (a['updated_at'] as String).compareTo(b['updated_at'] as String);
        return t != 0 ? t : (a['id'] as String).compareTo(b['id'] as String);
      });
    return rows
        .where((row) {
          if (after.id.isEmpty) return true;
          final t = (row['updated_at'] as String).compareTo(after.updatedAt);
          return t > 0 ||
              (t == 0 && (row['id'] as String).compareTo(after.id) > 0);
        })
        .take(limit)
        .toList();
  }
}

List<Map<String, dynamic>> _subscriptions(int count, {required int merchants}) {
  final base = DateTime.utc(2026, 6, 1);
  return [
    for (var i = 0; i < count; i++)
      {
        'id': 'srv-sub-${i.toString().padLeft(5, '0')}',
        'local_id': 'loc-sub-${i.toString().padLeft(5, '0')}',
        // Repeat across a small merchant set → distinct keys ≪ rows.
        'merchant_id': null,
        'name': 'Merchant ${i % merchants}',
        'amount': 10.0 + i,
        'currency': 'SAR',
        'frequency': 'monthly',
        'type': 'subscription',
        'next_due_date': base.toIso8601String(),
        'created_at': base.toIso8601String(),
        'updated_at': base.add(Duration(seconds: i)).toIso8601String(),
        'deleted_at': null,
      },
  ];
}

List<Map<String, dynamic>> _budgets(int count, {required int categories}) {
  final base = DateTime.utc(2026, 6, 1);
  return [
    for (var i = 0; i < count; i++)
      {
        'id': 'srv-bud-${i.toString().padLeft(5, '0')}',
        'local_id': 'loc-bud-${i.toString().padLeft(5, '0')}',
        // Reuse a small set of seeded category keys.
        'category_id': 'perf_key_${i % categories}',
        'amount': 100.0 + i,
        'period': 'monthly',
        'start_date': base.toIso8601String(),
        'updated_at': base.add(Duration(seconds: i)).toIso8601String(),
        'deleted_at': null,
      },
  ];
}

Future<int> _pullSelects(
  String enabledEntity,
  Map<String, List<Map<String, dynamic>>> byTable,
) async {
  final counting = await openCountingDb();
  try {
    // Seed the categories the budget rows reference (perf_key_0..11 exist).
    await seedFixtures(counting.db, count: 0);
    final pull = PlanningPullService(
      db: counting.db,
      isEnabled: (entityType) => entityType == enabledEntity,
      getAuthUserId: () async => 'user-1',
      remoteSource: _FakePlanningSource(byTable),
      pageSize: 5000,
    
    // C-3: covers pull MECHANICS; consent is asserted in
    // financial_pull_consent_test.dart.
    mayEgress: () async => true,
  );
    counting.counter.reset();
    await pull.pull();
    return counting.counter.selects;
  } finally {
    await counting.close();
  }
}

void main() {
  test('PlanningPull subscriptions: SELECTs O(distinct merchants + chunks)',
      () async {
    final at100 = await _pullSelects(
      PlanningOutboxQueue.subscriptionsEntityType,
      {'user_subscriptions': _subscriptions(100, merchants: 5)},
    );
    final at1000 = await _pullSelects(
      PlanningOutboxQueue.subscriptionsEntityType,
      {'user_subscriptions': _subscriptions(1000, merchants: 5)},
    );
    // Old path: ~ (findLocalId 1–2 + meta 1 + ensureMerchant 1–2) per row →
    // hundreds/thousands of SELECTs. New: cursor + identity(2) + merchant(2),
    // flat except for the extra chunk at 1,000 ids.
    expect(at100, lessThan(12));
    expect(at1000, lessThan(12));
    expect(at1000 - at100, lessThanOrEqualTo(4),
        reason: 'growth is O(chunks), not O(rows)');
  });

  test('PlanningPull budgets: SELECTs O(distinct categories + chunks)',
      () async {
    final at100 = await _pullSelects(
      PlanningOutboxQueue.budgetsEntityType,
      {'user_budgets': _budgets(100, categories: 6)},
    );
    final at1000 = await _pullSelects(
      PlanningOutboxQueue.budgetsEntityType,
      {'user_budgets': _budgets(1000, categories: 6)},
    );
    expect(at100, lessThan(12));
    expect(at1000, lessThan(12));
    expect(at1000 - at100, lessThanOrEqualTo(4),
        reason: 'growth is O(chunks), not O(rows)');
  });
}
