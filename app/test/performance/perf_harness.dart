// Phase-7 Batch-2 — deterministic performance harness (MALI-029/030/073n/038).
//
// Provides: (1) synthetic, NON-FINANCIAL fixtures at representative sizes;
// (2) a Drift QueryInterceptor that counts SQL statements by kind (the stable,
// machine-measurable budget surface — NOT wall-clock); (3) an EXPLAIN QUERY PLAN
// helper for the hot-path index audit. No real user data is ever used.
import 'dart:async';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/sql_value_codec.dart';

class _PerfKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'perf-key';
  @override
  Future<String?> readStoredKey() async => 'perf-key';
}

/// Counts SQL statements issued to the executor, grouped by kind. A batched write
/// is ONE round-trip regardless of row count, so `batched` staying flat while row
/// count grows is the proof that a loop was replaced by a set-based operation.
class StatementCounter extends QueryInterceptor {
  int selects = 0;
  int inserts = 0;
  int updates = 0;
  int deletes = 0;
  int customs = 0;
  int batched = 0;
  int batchedRows = 0;
  // B2-C — total ROWS returned across all SELECTs. `selects` counts statements
  // (a whole-ledger getAll is ONE statement returning N rows), so proving a
  // provider does not materialize the whole ledger needs the row count, not the
  // statement count.
  int selectRows = 0;

  /// Total individual statements (a batch counts as 1 — that is the point).
  int get total => selects + inserts + updates + deletes + customs + batched;

  void reset() {
    selects = inserts = updates = deletes = customs = batched = batchedRows = 0;
    selectRows = 0;
  }

  Map<String, int> snapshot() => {
        'select': selects,
        'insert': inserts,
        'update': updates,
        'delete': deletes,
        'custom': customs,
        'batched': batched,
        'batchedRows': batchedRows,
        'selectRows': selectRows,
        'total': total,
      };

  @override
  Future<List<Map<String, Object?>>> runSelect(
      QueryExecutor executor, String statement, List<Object?> args) async {
    selects++;
    final rows = await super.runSelect(executor, statement, args);
    selectRows += rows.length;
    return rows;
  }

  @override
  Future<int> runInsert(
      QueryExecutor executor, String statement, List<Object?> args) {
    inserts++;
    return super.runInsert(executor, statement, args);
  }

  @override
  Future<int> runUpdate(
      QueryExecutor executor, String statement, List<Object?> args) {
    updates++;
    return super.runUpdate(executor, statement, args);
  }

  @override
  Future<int> runDelete(
      QueryExecutor executor, String statement, List<Object?> args) {
    deletes++;
    return super.runDelete(executor, statement, args);
  }

  @override
  Future<void> runCustom(
      QueryExecutor executor, String statement, List<Object?> args) {
    customs++;
    return super.runCustom(executor, statement, args);
  }

  @override
  Future<void> runBatched(QueryExecutor executor, BatchedStatements statements) {
    batched++;
    for (final arg in statements.arguments) {
      batchedRows += 1;
      // `arg` is one row's argument set; counting them gives rows-per-batch.
      arg.hashCode; // no-op reference to keep the analyzer happy
    }
    return super.runBatched(executor, statements);
  }
}

class CountingDb {
  CountingDb(this.db, this.counter);
  final AppDatabase db;
  final StatementCounter counter;

  Future<void> close() => db.close();
}

/// Opens an in-memory encrypted-schema AppDatabase whose executor is wrapped by a
/// [StatementCounter]. Open/migration/seed statements are already counted, so call
/// `counter.reset()` after seeding to measure only the operation under test.
Future<CountingDb> openCountingDb() async {
  final counter = StatementCounter();
  final db = await AppDatabase.open(
    executor: NativeDatabase.memory().interceptWith(counter),
    keyStore: _PerfKeyStore(),
  );
  return CountingDb(db, counter);
}

/// Number of synthetic accounts/categories the fixtures spread rows across.
const int perfAccountCount = 8;
const int perfCategoryCount = 12;

/// Seeds [count] synthetic transactions (plus [perfAccountCount] accounts and
/// [perfCategoryCount] categories) spread across accounts, categories, statuses,
/// types and a monotonic occurred_at range. Fast: chunked multi-row INSERTs in one
/// transaction. Returns the created account/category ids for query fixtures.
Future<({List<String> accountIds, List<String> categoryIds})> seedFixtures(
  AppDatabase db, {
  required int count,
}) async {
  final now = DateTime.utc(2026, 1, 1);
  final accountIds = [for (var i = 0; i < perfAccountCount; i++) 'acct-$i'];
  final categoryIds = [for (var i = 0; i < perfCategoryCount; i++) 'cat-$i'];

  await db.transaction(() async {
    for (var i = 0; i < perfAccountCount; i++) {
      await db.customStatement(
        "INSERT INTO accounts(id, name, currency, type, created_at, updated_at) "
        "VALUES ('acct-$i', 'Account $i', 'SAR', 'bank', "
        "'${dateTimeToSql(now)}', '${dateTimeToSql(now)}');",
      );
    }
    for (var i = 0; i < perfCategoryCount; i++) {
      await db.customStatement(
        "INSERT INTO categories(id, key, name_ar, icon, color, is_income, sort_order) "
        "VALUES ('cat-$i', 'perf_key_$i', 'فئة $i', 'tag', '#112233', "
        "${i == 0 ? 1 : 0}, $i);",
      );
    }

    const chunk = 250;
    final buffer = StringBuffer();
    for (var start = 0; start < count; start += chunk) {
      final end = (start + chunk) < count ? (start + chunk) : count;
      buffer
        ..clear()
        ..write(
          'INSERT INTO transactions(id, amount, currency, account_id, category_id, '
          'type, source, occurred_at, raw_message, parse_confidence, status, '
          'created_at, updated_at, direction) VALUES ',
        );
      for (var i = start; i < end; i++) {
        final acct = accountIds[i % perfAccountCount];
        final cat = categoryIds[i % perfCategoryCount];
        final type = (i % 5 == 0) ? 'income' : 'payment';
        final status = (i % 11 == 0)
            ? 'ignored'
            : (i % 7 == 0)
                ? 'pending'
                : 'confirmed';
        // occurred_at spreads backwards so ordering by it is meaningful.
        final occurred = dateTimeToSql(now.add(Duration(minutes: i)));
        final amount = 10.0 + (i % 500);
        if (i > start) buffer.write(', ');
        buffer.write(
          "('txn-$i', $amount, 'SAR', '$acct', '$cat', '$type', 'bank', "
          "'$occurred', 'synthetic $i', 0.9, '$status', "
          "'$occurred', '$occurred', '${type == 'income' ? 'credit' : 'debit'}')",
        );
      }
      buffer.write(';');
      await db.customStatement(buffer.toString());
    }
  });

  return (accountIds: accountIds, categoryIds: categoryIds);
}

/// Runs `EXPLAIN QUERY PLAN <sql>` and returns each plan step's `detail` text.
Future<List<String>> explainQueryPlan(
  AppDatabase db,
  String sql, {
  List<Variable> variables = const [],
}) async {
  final rows =
      await db.customSelect('EXPLAIN QUERY PLAN $sql', variables: variables).get();
  return rows.map((r) => r.read<String>('detail')).toList();
}

/// True when no plan step is a full-table SCAN of [table] (i.e. every access to
/// [table] is a SEARCH, typically via an index). SQLite renders a full scan as
/// `SCAN <table>` and an indexed access as `SEARCH <table> USING ... INDEX ...`.
bool planAvoidsFullScanOf(List<String> plan, String table) {
  for (final step in plan) {
    // A full scan reads as "SCAN <table>" (no "USING INDEX"); an indexed read is
    // "SEARCH <table> USING [COVERING ]INDEX ...".
    if (step.contains('SCAN $table') && !step.contains('USING')) return false;
  }
  return true;
}

/// True when some plan step searches [table] using an index.
bool planUsesIndexOn(List<String> plan, String table) {
  return plan.any((s) => s.contains('SEARCH $table') && s.contains('INDEX'));
}
