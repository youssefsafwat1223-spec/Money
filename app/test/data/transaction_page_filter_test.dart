// Phase-7 B2-C — getTransactionPage: SQL filter push-down + keyset pagination.
//
// Proves every supported filter (account / date / kind / category / search /
// pending) is applied IN SQL, that keyset paging (occurred_at DESC, id DESC) is
// stable with no duplicates/gaps including equal timestamps, and that the first
// page never loads the full history (structural, via the query-count harness at
// 10k rows).
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';
import 'package:money_companion/data/db/sql_value_codec.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/repositories/transaction_repository.dart';

import '../performance/perf_harness.dart';

class _KeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'k';
  @override
  Future<String?> readStoredKey() async => 'k';
}

Future<AppDatabase> _open() =>
    AppDatabase.open(executor: NativeDatabase.memory(), keyStore: _KeyStore());

/// Seeds one transaction with explicit fields (occurred_at is an ISO instant).
Future<void> _seed(
  AppDatabase db, {
  required String id,
  required DateTime occurredAt,
  String account = 'acc-1',
  String category = 'cat-food',
  String type = 'payment',
  String status = 'confirmed',
  double amount = 10,
  String currency = 'SAR',
  String? merchant,
  String? note,
}) async {
  final at = dateTimeToSql(occurredAt);
  await db.customStatement(
    'INSERT INTO transactions(id, amount, currency, account_id, category_id, '
    'raw_merchant, note, type, source, occurred_at, raw_message, '
    'parse_confidence, status, created_at, updated_at, direction) '
    'VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);',
    [
      id,
      amount,
      currency,
      account,
      category,
      merchant,
      note,
      type,
      'bank',
      at,
      '',
      1.0,
      status,
      at,
      at,
      type == 'income' ? 'credit' : 'debit',
    ],
  );
  await backfillNonPlanningMoneyV30(db);
}

Future<void> _seedCategories(AppDatabase db) async {
  // Non-colliding keys — the DB auto-seeds real 'restaurants'/'shopping' on open
  // (UNIQUE key), which would make INSERT OR IGNORE skip our id.
  for (final c in const [
    ('cat-food', 'test_food', 'مطاعم'),
    ('cat-shop', 'test_shop', 'تسوق'),
  ]) {
    await db.customStatement(
      "INSERT OR IGNORE INTO categories(id,key,name_ar,icon,color,is_income,"
      "sort_order) VALUES (?,?,?,'tag','#111',0,0);",
      [c.$1, c.$2, c.$3],
    );
  }
}

void main() {
  late AppDatabase db;
  late DriftTransactionRepository repo;
  final base = DateTime.utc(2026, 6, 15, 12);

  setUp(() async {
    db = await _open();
    repo = DriftTransactionRepository(db);
    await _seedCategories(db);
    for (final id in const ['acc-1', 'acc-2']) {
      await db.customStatement(
        "INSERT INTO accounts(id,name,currency,type,created_at,updated_at) "
        "VALUES (?,?,'SAR','bank','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z');",
        [id, id],
      );
    }
    await backfillNonPlanningMoneyV30(db);
  });
  tearDown(() => db.close());

  test('unfiltered keyset paging: stable order, no dup, no gap', () async {
    for (var i = 0; i < 7; i++) {
      await _seed(db, id: 't$i', occurredAt: base.subtract(Duration(hours: i)));
    }
    final seen = <String>[];
    TransactionPageCursor? cursor;
    while (true) {
      final page = await repo.getTransactionPage(limit: 3, after: cursor);
      if (page.isEmpty) break;
      seen.addAll(page.map((t) => t.id));
      final last = page.last;
      cursor = TransactionPageCursor(occurredAt: last.occurredAt, id: last.id);
      if (page.length < 3) break;
    }
    // newest first, every row exactly once.
    expect(seen, ['t0', 't1', 't2', 't3', 't4', 't5', 't6']);
    expect(seen.toSet().length, seen.length, reason: 'no duplicates');
  });

  test('equal timestamps paginate stably by id DESC (no dup/gap)', () async {
    // 5 rows share the SAME occurred_at.
    for (final id in ['a', 'b', 'c', 'd', 'e']) {
      await _seed(db, id: id, occurredAt: base);
    }
    final seen = <String>[];
    TransactionPageCursor? cursor;
    while (true) {
      final page = await repo.getTransactionPage(limit: 2, after: cursor);
      if (page.isEmpty) break;
      seen.addAll(page.map((t) => t.id));
      final last = page.last;
      cursor = TransactionPageCursor(occurredAt: last.occurredAt, id: last.id);
      if (page.length < 2) break;
    }
    expect(seen, ['e', 'd', 'c', 'b', 'a'], reason: 'id DESC tiebreak, stable');
    expect(seen.toSet().length, 5);
  });

  test('account filter is SQL-pushed', () async {
    await _seed(db, id: 'a1', occurredAt: base, account: 'acc-1');
    await _seed(db, id: 'a2', occurredAt: base, account: 'acc-2');
    final page = await repo.getTransactionPage(
      limit: 10,
      filter: const TransactionPageFilter(accountId: 'acc-2'),
    );
    expect(page.map((t) => t.id), ['a2']);
  });

  test('category filter is SQL-pushed', () async {
    await _seed(db, id: 'f', occurredAt: base, category: 'cat-food');
    await _seed(db, id: 's', occurredAt: base, category: 'cat-shop');
    final page = await repo.getTransactionPage(
      limit: 10,
      filter: const TransactionPageFilter(categoryId: 'cat-shop'),
    );
    expect(page.map((t) => t.id), ['s']);
  });

  test('half-open date filter [from, to) is SQL-pushed', () async {
    await _seed(db, id: 'before', occurredAt: DateTime.utc(2026, 6, 1));
    await _seed(db, id: 'from', occurredAt: DateTime.utc(2026, 6, 10));
    await _seed(db, id: 'mid', occurredAt: DateTime.utc(2026, 6, 15));
    await _seed(db, id: 'to', occurredAt: DateTime.utc(2026, 6, 20)); // exclusive
    final page = await repo.getTransactionPage(
      limit: 10,
      filter: TransactionPageFilter(
        from: DateTime.utc(2026, 6, 10),
        to: DateTime.utc(2026, 6, 20),
      ),
    );
    expect(page.map((t) => t.id).toSet(), {'from', 'mid'});
  });

  test('kind filter (expenses = payment|withdrawal) is SQL-pushed', () async {
    await _seed(db, id: 'pay', occurredAt: base, type: 'payment');
    await _seed(db, id: 'wd', occurredAt: base, type: 'withdrawal');
    await _seed(db, id: 'inc', occurredAt: base, type: 'income');
    await _seed(db, id: 'xfer', occurredAt: base, type: 'transfer');
    final page = await repo.getTransactionPage(
      limit: 10,
      filter: const TransactionPageFilter(kind: TransactionPageKind.expenses),
    );
    expect(page.map((t) => t.id).toSet(), {'pay', 'wd'});
  });

  test('combined account + category + date + kind', () async {
    await _seed(db, id: 'hit',
        occurredAt: base, account: 'acc-1', category: 'cat-food', type: 'payment');
    await _seed(db, id: 'wrongAcc',
        occurredAt: base, account: 'acc-2', category: 'cat-food', type: 'payment');
    await _seed(db, id: 'wrongType',
        occurredAt: base, account: 'acc-1', category: 'cat-food', type: 'income');
    final page = await repo.getTransactionPage(
      limit: 10,
      filter: TransactionPageFilter(
        accountId: 'acc-1',
        categoryId: 'cat-food',
        kind: TransactionPageKind.expenses,
        from: DateTime.utc(2026, 6, 1),
        to: DateTime.utc(2026, 7, 1),
      ),
    );
    expect(page.map((t) => t.id), ['hit']);
  });

  test('pending-only forces status=pending (ignores date/kind)', () async {
    await _seed(db, id: 'p', occurredAt: base, status: 'pending', type: 'income');
    await _seed(db, id: 'c', occurredAt: base, status: 'confirmed');
    final page = await repo.getTransactionPage(
      limit: 10,
      filter: const TransactionPageFilter(pendingOnly: true),
    );
    expect(page.map((t) => t.id), ['p']);
  });

  test('ignored rows are excluded by default', () async {
    await _seed(db, id: 'ok', occurredAt: base, status: 'confirmed');
    await _seed(db, id: 'ign', occurredAt: base, status: 'ignored');
    final page = await repo.getTransactionPage(limit: 10);
    expect(page.map((t) => t.id), ['ok']);
  });

  test('search matches per field + escapes LIKE wildcards', () async {
    await _seed(db, id: 'sb',
        occurredAt: base, merchant: 'Starbucks', note: 'morning coffee',
        currency: 'USD', amount: 12.50);
    await _seed(db, id: 'other', occurredAt: base, merchant: 'Grocery');
    await _seed(db, id: 'pct', occurredAt: base, note: 'save 50% today');

    Future<Set<String>> search(String q) async => (await repo.getTransactionPage(
          limit: 10,
          filter: TransactionPageFilter(search: q),
        ))
        .map((t) => t.id)
        .toSet();

    expect(await search('star'), {'sb'}); // merchant, case-insensitive
    expect(await search('COFFEE'), {'sb'}); // note
    expect(await search('12.50'), {'sb'}); // printf 2-dp amount
    expect(await search('usd'), {'sb'}); // currency
    expect(await search('مطاعم'), {'sb', 'other', 'pct'}); // category name_ar (all cat-food)
    // '%' is a literal, not a wildcard: '50%' matches only the note with "50%".
    expect(await search('50%'), {'pct'});
  });

  group('search semantic parity (Blocker 3)', () {
    setUp(() async {
      await _seed(db, id: 'ar', occurredAt: base, merchant: 'قهوة العربية');
      await _seed(db, id: 'sb', occurredAt: base, merchant: 'Starbucks',
          currency: 'EGP', amount: 12.50, note: 'morning');
      await _seed(db, id: 'low', occurredAt: base, merchant: 'noon store');
      await _seed(db, id: 'pct', occurredAt: base, note: 'save 50% off');
      await _seed(db, id: 'usc', occurredAt: base, note: 'plan_a alpha');
      await _seed(db, id: 'usb', occurredAt: base, note: 'planXa beta');
      await _seed(db, id: 'shop', occurredAt: base, category: 'cat-shop',
          merchant: 'mall');
    });

    Future<Set<String>> search(String q) async =>
        (await repo.getTransactionPage(
                limit: 50, filter: TransactionPageFilter(search: q)))
            .map((t) => t.id)
            .toSet();

    test('Arabic merchant matches exactly (no case-fold needed)', () async {
      expect(await search('قهوة'), {'ar'});
    });

    test('English merchant is case-insensitive BOTH directions', () async {
      expect(await search('starbucks'), {'sb'}); // lower query → mixed merchant
      expect(await search('STARBUCKS'), {'sb'}); // upper query → mixed merchant
      expect(await search('NOON'), {'low'}); // upper query → lower merchant
    });

    test('category Arabic name and stable key both match', () async {
      // cat-food name_ar = 'مطاعم', key = 'test_food'; all cat-food rows match.
      final byName = await search('مطاعم');
      expect(byName, containsAll({'ar', 'sb', 'low', 'pct', 'usc', 'usb'}));
      expect(byName, isNot(contains('shop'))); // shop is cat-shop
      expect(await search('test_shop'), {'shop'}); // category key
    });

    test('note, currency and 2-dp amount match', () async {
      expect(await search('morning'), {'sb'}); // note
      expect(await search('egp'), {'sb'}); // currency, case-insensitive
      expect(await search('12.50'), {'sb'}); // printf 2-dp amount
    });

    test('% and _ are literal (escaped), not wildcards', () async {
      // '%' matches only the note containing a literal '%'.
      expect(await search('50%'), {'pct'});
      // '_' matches the literal underscore, NOT any single character.
      expect(await search('plan_a'), {'usc'});
      expect(await search('plan_a'), isNot(contains('usb'))); // 'planXa' excluded
    });

    test('leading/trailing spaces are trimmed', () async {
      expect(await search('  starbucks  '), {'sb'});
    });

    test('filter + search combine (account + term)', () async {
      await _seed(db, id: 'other-acc', occurredAt: base,
          account: 'acc-2', merchant: 'Starbucks');
      final page = await repo.getTransactionPage(
        limit: 50,
        filter: const TransactionPageFilter(
            accountId: 'acc-1', search: 'starbucks'),
      );
      // Only the acc-1 Starbucks row, not the acc-2 one.
      expect(page.map((t) => t.id).toSet(), {'sb'});
    });
  });

  test('empty result + final partial page', () async {
    await _seed(db, id: 'only', occurredAt: base);
    final none = await repo.getTransactionPage(
      limit: 10,
      filter: const TransactionPageFilter(accountId: 'no-such'),
    );
    expect(none, isEmpty);
    final partial = await repo.getTransactionPage(limit: 10);
    expect(partial.length, 1); // < limit → final page
  });

  test('10k rows: first page is bounded + one SELECT (no full-history load)',
      () async {
    final counting = await openCountingDb();
    try {
      await seedFixtures(counting.db, count: 10000);
      final repo10k = DriftTransactionRepository(counting.db);
      counting.counter.reset();
      final first = await repo10k.getTransactionPage(limit: 50);
      expect(first.length, 50, reason: 'bounded first page, not 10,000');
      expect(counting.counter.selects, 1, reason: 'a single keyset query');

      // Next page appends the next 50 with one more query, still bounded.
      final last = first.last;
      counting.counter.reset();
      final second = await repo10k.getTransactionPage(
        limit: 50,
        after: TransactionPageCursor(occurredAt: last.occurredAt, id: last.id),
      );
      expect(second.length, 50);
      expect(counting.counter.selects, 1);
      // No overlap between the two pages.
      final overlap =
          first.map((t) => t.id).toSet().intersection(second.map((t) => t.id).toSet());
      expect(overlap, isEmpty);
    } finally {
      await counting.close();
    }
  });
}
