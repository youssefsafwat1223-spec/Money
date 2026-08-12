// Phase-7 Batch-2 §MALI-030 — `largestExpenses` is a real bounded SQL top-N: on a
// 10k table only the requested N rows enter Dart (was: getAll() the whole table
// then Dart-sort). Proves exact N, correct top-N vs a known fixture, deterministic
// order, and that the bulk (non-top) rows never come back.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';
import 'package:money_companion/data/db/sql_value_codec.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';

import 'perf_harness.dart';

class _K implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'k';
  @override
  Future<String?> readStoredKey() async => 'k';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late DriftTransactionRepository repo;

  setUp(() async {
    db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _K());
    repo = DriftTransactionRepository(db);
    // 10k bulk rows (small amounts 10..509) + 12 KNOWN-large confirmed payments.
    await seedFixtures(db, count: 10000);
    final occurred = dateTimeToSql(DateTime.utc(2026, 6, 1, 12));
    for (var i = 0; i < 12; i++) {
      final amount = 1000000 + (12 - i); // 1000012 .. 1000001, distinct
      await db.customStatement(
        "INSERT INTO transactions(id, amount, currency, account_id, category_id, "
        "type, source, occurred_at, raw_message, parse_confidence, status, "
        "created_at, updated_at, direction) VALUES "
        "('big-$i', $amount, 'SAR', 'acct-0', 'cat-0', 'payment', 'bank', "
        "'$occurred', 'big $i', 0.9, 'confirmed', '$occurred', '$occurred', "
        "'debit');",
      );
    }
    await backfillNonPlanningMoneyV30(db);
  });
  tearDown(() => db.close());

  test('returns exactly N, the correct top-N, in descending order', () async {
    final result = await repo.largestExpenses(
      from: DateTime.utc(2026, 1, 1),
      to: DateTime.utc(2026, 12, 31),
      limit: 10,
    );
    // Exactly the bounded N — never the whole 10k+ table.
    expect(result.length, 10);
    // The top 10 of the 12 known-large rows, in descending amount order.
    final amounts = result.map((t) => t.amount).toList();
    expect(amounts,
        [1000012, 1000011, 1000010, 1000009, 1000008, 1000007, 1000006, 1000005, 1000004, 1000003]);
    // None of the small bulk rows leaked in (proves it did NOT take the first N).
    expect(amounts.every((a) => a >= 1000003), isTrue);
  });

  test('honours the requested limit independent of table size', () async {
    final three = await repo.largestExpenses(
      from: DateTime.utc(2026, 1, 1),
      to: DateTime.utc(2026, 12, 31),
      limit: 3,
    );
    expect(three.length, 3);
    expect(three.map((t) => t.amount), [1000012, 1000011, 1000010]);
  });
}
