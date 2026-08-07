// Phase-7 Batch-2 §MALI-073n — hot-path index audit via real EXPLAIN QUERY PLAN.
//
// Each case prints the observed plan (before/after evidence for the report) and
// asserts the audited hot-path queries do NOT full-scan `transactions`. Run BEFORE
// the account_id/category_id indexes exist → the account/category cases fail with a
// `SCAN transactions` plan (the baseline). Run AFTER → they SEARCH via index.
import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';

import 'perf_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late CountingDb env;
  late List<String> accountIds;
  late List<String> categoryIds;

  setUp(() async {
    env = await openCountingDb();
    final ids = await seedFixtures(env.db, count: 2000);
    accountIds = ids.accountIds;
    categoryIds = ids.categoryIds;
    // ANALYZE so the planner has real selectivity stats (as production would after
    // enough usage); the index decision must hold with statistics present.
    await env.db.customStatement('ANALYZE;');
  });

  tearDown(() => env.close());

  Future<List<String>> plan(String sql, [List<Variable> vars = const []]) async {
    final steps = await explainQueryPlan(env.db, sql, variables: vars);
    // ignore: avoid_print
    print('\nEXPLAIN QUERY PLAN\n  $sql\n${steps.map((s) => '   → $s').join('\n')}');
    return steps;
  }

  test('account-scoped recent list uses an index on account_id (no full scan)',
      () async {
    final steps = await plan(
      "SELECT * FROM transactions WHERE status = 'confirmed' AND account_id = ? "
      'ORDER BY occurred_at DESC LIMIT 50;',
      [Variable.withString(accountIds.first)],
    );
    expect(planAvoidsFullScanOf(steps, 'transactions'), isTrue,
        reason: 'account_id filter must not full-scan transactions');
    expect(planUsesIndexOn(steps, 'transactions'), isTrue);
  });

  test('account-scoped aggregate uses an index on account_id (no full scan)',
      () async {
    final steps = await plan(
      "SELECT CAST(COALESCE(SUM(amount), 0) AS REAL) AS total FROM transactions "
      "WHERE status = 'confirmed' AND occurred_at >= ? AND occurred_at < ? "
      'AND account_id = ?;',
      [
        Variable.withString('2026-01-01T00:00:00.000Z'),
        Variable.withString('2026-12-31T00:00:00.000Z'),
        Variable.withString(accountIds.first),
      ],
    );
    expect(planAvoidsFullScanOf(steps, 'transactions'), isTrue);
  });

  test('category filter uses an index on category_id (no full scan)', () async {
    final steps = await plan(
      "SELECT * FROM transactions WHERE status = 'confirmed' AND category_id = ?;",
      [Variable.withString(categoryIds.first)],
    );
    expect(planAvoidsFullScanOf(steps, 'transactions'), isTrue,
        reason: 'category_id filter must not full-scan transactions');
    expect(planUsesIndexOn(steps, 'transactions'), isTrue);
  });

  test('list pagination uses the occurred_at index for ordering', () async {
    // Control case (idx_transactions_occurred_at predates Batch-2): an unfiltered
    // ORDER BY occurred_at + LIMIT reads the index in order (SCAN ... USING INDEX),
    // which is optimal — the point is it does NOT full-scan the raw table.
    final steps = await plan(
      "SELECT * FROM transactions WHERE status != 'ignored' "
      'ORDER BY occurred_at DESC, id DESC LIMIT 500 OFFSET 0;',
    );
    expect(steps.any((s) => s.contains('idx_transactions_occurred_at')), isTrue,
        reason: 'occurred_at ordering should use idx_transactions_occurred_at');
    expect(planAvoidsFullScanOf(steps, 'transactions'), isTrue);
  });
}
