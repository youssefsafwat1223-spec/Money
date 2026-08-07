// Phase-7 Batch-2-A (MALI-029) — query-count evidence for AccountsPullService.
//
// Proves the batched identity resolution makes the pull's SELECT count a
// function of pages/chunks, NOT of row count: 100 rows and 1,000 rows resolve
// with the SAME (small, constant) number of SELECTs. Writes (one per changed
// row) are the only per-row cost and are unavoidable.
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/sync/sync_cursor.dart';
import 'package:money_companion/features/planning_sync/services/accounts_pull_service.dart';

import 'perf_harness.dart';

/// Minimal cursor-honouring remote: returns synthetic server account rows
/// ordered by (updated_at, id), after the cursor, up to [limit].
class _FakeAccountsSource implements AccountsRemoteSource {
  _FakeAccountsSource(this.rows);
  final List<Map<String, dynamic>> rows;

  @override
  Future<List<Map<String, dynamic>>> fetchRows({
    required SyncCursor after,
    int limit = 200,
  }) async {
    final ordered = [...rows]..sort((a, b) {
        final t = (a['updated_at'] as String).compareTo(b['updated_at'] as String);
        return t != 0 ? t : (a['id'] as String).compareTo(b['id'] as String);
      });
    return ordered
        .where((row) {
          if (after.id.isEmpty) return true;
          final t = (row['updated_at'] as String).compareTo(after.updatedAt);
          return t > 0 || (t == 0 && (row['id'] as String).compareTo(after.id) > 0);
        })
        .take(limit)
        .toList();
  }
}

List<Map<String, dynamic>> _serverAccounts(int count) {
  final base = DateTime.utc(2026, 6, 1);
  return [
    for (var i = 0; i < count; i++)
      {
        'id': 'srv-acct-${i.toString().padLeft(5, '0')}',
        'local_id': 'local-acct-${i.toString().padLeft(5, '0')}',
        'name': 'Account $i',
        'currency': 'SAR',
        'type': 'bank',
        'is_default': i == 0,
        'sort_order': i,
        'updated_at': base.add(Duration(seconds: i)).toIso8601String(),
        'created_at': base.toIso8601String(),
        'deleted_at': null,
      },
  ];
}

Future<int> _pullSelects(int count) async {
  final counting = await openCountingDb();
  try {
    final pull = AccountsPullService(
      db: counting.db,
      isEnabled: () => true,
      getAuthUserId: () async => 'user-1',
      remoteSource: _FakeAccountsSource(_serverAccounts(count)),
      pageSize: 5000, // single page so we measure per-page SELECT cost cleanly
    );
    counting.counter.reset();
    final result = await pull.pull();
    expect(result.imported, count, reason: 'all rows are new imports');
    return counting.counter.selects;
  } finally {
    await counting.close();
  }
}

void main() {
  test('AccountsPull SELECT count is O(chunks), not O(rows)', () async {
    final at100 = await _pullSelects(100);
    final at1000 = await _pullSelects(1000);

    // Before batching this was ~2–3 SELECTs PER ROW (findLocalId + meta) →
    // ~200 at 100 rows, ~2,000 at 1,000 rows. After, it is a small per-page
    // constant: the cursor read plus the two bounded identity lookups.
    expect(at100, lessThan(10), reason: 'bounded, nowhere near 100');
    expect(at1000, lessThan(10), reason: 'bounded, nowhere near 1,000');
    // 10× the rows only adds the extra chunk per bounded lookup (1,000 distinct
    // ids = 2 chunks at size 500), i.e. growth is O(ceil(distinct/chunk)), NOT
    // O(rows). At most +2 SELECTs (one extra chunk for server-id + local-id).
    expect(at1000 - at100, lessThanOrEqualTo(2),
        reason: 'growth is O(chunks), not O(rows)');
  });

  test('AccountsPull idempotent replay writes nothing and stays flat',
      () async {
    final counting = await openCountingDb();
    try {
      final source = _FakeAccountsSource(_serverAccounts(500));
      final pull = AccountsPullService(
        db: counting.db,
        isEnabled: () => true,
        getAuthUserId: () async => 'user-1',
        remoteSource: source,
        pageSize: 5000,
      );
      await pull.pull(); // first pull imports everything

      // A second pull over the same server state must skip every row (unchanged)
      // and perform NO write — and still only a per-page constant of SELECTs.
      counting.counter.reset();
      final replay = await pull.pull();
      expect(replay.imported, 0);
      expect(replay.updated, 0);
      expect(counting.counter.inserts, 0);
      expect(counting.counter.updates, 0,
          reason: 'unchanged rows are not re-written (no dbRevision churn)');
      expect(counting.counter.selects, lessThan(10));
    } finally {
      await counting.close();
    }
  });
}
