import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';

// MALI-026 (B8-3 Step 5 Commit 4 §3) — migration PERFORMANCE evidence. The
// non-planning v30 backfill is measured at 1k / 10k / 100k transaction rows to
// expose growth SHAPE (accidental O(n²)), not an invented release threshold.

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<int> backfillMs(int rows) async {
    final db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
    addTearDown(db.close);
    // Generate `rows` v29-shaped transactions (REAL + currency, `_minor` NULL)
    // fast via a recursive CTE, then time ONLY the backfill.
    await db.customStatement('''
      INSERT INTO transactions(
        id, amount, currency, raw_merchant, type, source, occurred_at,
        raw_message, parse_confidence, status, created_at, updated_at)
      WITH RECURSIVE seq(n) AS (
        SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < $rows)
      SELECT 'tx' || n, ((n % 100000) + 0.5), 'EGP', 'm', 'payment', 'manual',
             '2026-08-01T00:00:00Z', 'r', 1.0, 'confirmed',
             '2026-08-01T00:00:00Z', '2026-08-01T00:00:00Z'
      FROM seq;
    ''');
    final sw = Stopwatch()..start();
    await backfillNonPlanningMoneyV30(db);
    sw.stop();
    // Correctness spot-check: minor is populated for a sample row.
    final r = await db
        .customSelect("SELECT amount_minor AS m FROM transactions WHERE id='tx1';")
        .getSingle();
    expect(r.read<int>('m'), 150); // n=1 → 1.5 EGP → 150 minor (backfill ran)
    return sw.elapsedMilliseconds;
  }

  test('§3 v30 backfill scales sub-quadratically (1k / 10k / 100k)', () async {
    final t1k = await backfillMs(1000);
    final t10k = await backfillMs(10000);
    final t100k = await backfillMs(100000);
    // ignore: avoid_print
    print('[v30-backfill-perf] 1k=${t1k}ms 10k=${t10k}ms 100k=${t100k}ms');

    // Growth SHAPE: 10x the rows must not cost ~100x the time (that would signal
    // O(n²)). Allow generous constant overhead on the tiny 1k baseline. Compare
    // the two large steps where per-row cost dominates: 100k over 10k should be
    // roughly linear (≤ ~40x, not ~100x).
    expect(t100k, lessThan((t10k + 50) * 40),
        reason: '100k/10k growth looks super-linear (possible O(n^2))');
  });
}
