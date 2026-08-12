// Phase-7 B2-C closure (Blocker 1) — the residual provider paths that USED
// `getAll()` no longer materialize the whole ledger. Uses a real DB + real
// providers (override appDatabaseProvider only) and the row-counting harness:
// with 10,000 unrelated old transactions and a small current window, the
// SELECTs return a bounded number of ROWS, never ~10,000.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';
import 'package:money_companion/data/db/sql_value_codec.dart';
import 'package:money_companion/features/budgets/budgets_providers.dart';
import 'package:money_companion/features/cards/cards_providers.dart';
import 'package:money_companion/features/dashboard/dashboard_providers.dart';

import 'perf_harness.dart';

Future<void> _seedAccount(AppDatabase db, String id, String currency) async {
  await db.customStatement(
      "INSERT INTO accounts(id,name,currency,type,is_default,created_at,"
      "updated_at) VALUES (?,?,?,'bank',?, '2020-01-01T00:00:00Z',"
      "'2020-01-01T00:00:00Z');",
      [id, id, currency, id == 'acc-now' ? 1 : 0],
    );
  await backfillNonPlanningMoneyV30(db);
}

Future<void> _seedCategory(AppDatabase db) => db.customStatement(
      "INSERT OR IGNORE INTO categories(id,key,name_ar,icon,color,is_income,"
      "sort_order) VALUES ('cat-b','budget_cat','ميزانية','tag','#111',0,0);",
    );

/// Bulk-insert [count] confirmed payment transactions at [at] on [account].
Future<void> _seedTxns(
  AppDatabase db, {
  required int count,
  required DateTime at,
  required String account,
  required String idPrefix,
}) async {
  final ts = dateTimeToSql(at);
  await db.transaction(() async {
    const chunk = 400;
    for (var start = 0; start < count; start += chunk) {
      final end = (start + chunk) < count ? start + chunk : count;
      final buf = StringBuffer(
        'INSERT INTO transactions(id, amount, currency, account_id, category_id,'
        ' type, source, occurred_at, raw_message, parse_confidence, status,'
        ' created_at, updated_at, direction) VALUES ',
      );
      for (var i = start; i < end; i++) {
        if (i > start) buf.write(', ');
        buf.write("('$idPrefix-$i', 10, 'SAR', '$account', 'cat-b', 'payment',"
            " 'bank', '$ts', '', 1, 'confirmed', '$ts', '$ts', 'debit')");
      }
      buf.write(';');
      await db.customStatement(buf.toString());
    }
  });
  await backfillNonPlanningMoneyV30(db);
}

void main() {
  test('budgets provider: 10k old ledger + small current period is bounded',
      () async {
    final counting = await openCountingDb();
    final now = DateTime.now();
    final thisMonthStart = DateTime(now.year, now.month, 1);
    try {
      await _seedAccount(counting.db, 'acc-now', 'SAR');
      await _seedCategory(counting.db);
      // 10,000 confirmed payments in Jan 2020 (far outside this month) + 12 in
      // the current month.
      await _seedTxns(counting.db,
          count: 10000,
          at: DateTime.utc(2020, 1, 15, 12),
          account: 'acc-now',
          idPrefix: 'old');
      await _seedTxns(counting.db,
          count: 12,
          at: thisMonthStart.add(const Duration(days: 1, hours: 3)),
          account: 'acc-now',
          idPrefix: 'cur');
      // An active monthly category budget on the seeded 'cat-b' category.
      await counting.db.customStatement(
        "INSERT INTO budgets(id,category_id,amount,period,start_date,is_active,"
        "last_notified_spent_amount,last_notified_period_start,show_on_header) "
        "VALUES ('b1', 'cat-b', 1000, 'monthly', ?, 1, 0, "
        "'2000-01-01T00:00:00Z', 0);",
        [dateTimeToSql(thisMonthStart)],
      );

      final container = ProviderContainer(overrides: [
        appDatabaseProvider.overrideWithValue(counting.db),
      ]);
      addTearDown(container.dispose);
      counting.counter.reset();
      final view = await container.read(budgetsViewProvider.future);

      // The current-period history entry lists only this month's 12 rows.
      final current = view.historyEntries.where((e) => e.isCurrent).toList();
      expect(current, isNotEmpty);
      expect(current.first.transactions.length, 12,
          reason: 'only this-month line items, not the 10k old ones');
      // Crucially: the whole ledger was never materialised. The line-item load
      // is scoped to the period window; the 10,000 old rows are never read.
      expect(counting.counter.selectRows, lessThan(2000),
          reason: 'bounded to the period window, not O(ledger)');
    } finally {
      await counting.close();
    }
  });

  test('dashboard provider: 10k ledger currency/account bootstrap is bounded',
      () async {
    final counting = await openCountingDb();
    try {
      await _seedAccount(counting.db, 'acc-now', 'SAR');
      await _seedCategory(counting.db);
      // 10,000 rows that ALL already have an account → the null-account backfill
      // drain reads nothing; distinct-currency is a tiny set.
      await _seedTxns(counting.db,
          count: 10000,
          at: DateTime.utc(2020, 1, 15, 12),
          account: 'acc-now',
          idPrefix: 'd');
      final container = ProviderContainer(overrides: [
        appDatabaseProvider.overrideWithValue(counting.db),
      ]);
      addTearDown(container.dispose);
      counting.counter.reset();
      await container.read(dashboardDataProvider.future);
      expect(counting.counter.selectRows, lessThan(2000),
          reason: 'distinct-currency + bounded aggregates, never the 10k rows');
    } finally {
      await counting.close();
    }
  });

  test('cards picker provider: bounded search page over a 10k ledger', () async {
    final counting = await openCountingDb();
    try {
      await _seedAccount(counting.db, 'acc-now', 'SAR');
      await _seedCategory(counting.db);
      await _seedTxns(counting.db,
          count: 10000,
          at: DateTime.utc(2020, 1, 15, 12),
          account: 'acc-now',
          idPrefix: 'p');
      final container = ProviderContainer(overrides: [
        appDatabaseProvider.overrideWithValue(counting.db),
      ]);
      addTearDown(container.dispose);
      counting.counter.reset();
      final page = await container.read(pickTransactionsProvider('').future);
      expect(page.length, lessThanOrEqualTo(500), reason: 'bounded page');
      expect(counting.counter.selectRows, lessThan(1000),
          reason: 'one bounded page, not the whole 10k ledger');
    } finally {
      await counting.close();
    }
  });
}
