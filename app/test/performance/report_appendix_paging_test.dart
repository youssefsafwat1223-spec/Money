// Phase-7 Batch-2 §MALI-030 — the report appendix is read in bounded KEYSET pages:
// every confirmed in-range row appears exactly once, in stable (occurred_at DESC,
// id DESC) order, with no duplicate or gap between pages, and each page retains at
// most the requested limit (never the whole table).
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/sql_value_codec.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';

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
  const total = 1000;

  setUp(() async {
    db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _K());
    repo = DriftTransactionRepository(db);
    await db.customStatement(
      "INSERT INTO accounts(id, name, currency, type, created_at, updated_at) "
      "VALUES ('a0', 'A', 'SAR', 'bank', '2026-01-01', '2026-01-01');",
    );
    await db.customStatement(
      "INSERT INTO categories(id, key, name_ar, icon, color, is_income, sort_order) "
      "VALUES ('c0', 'k0', 'ف', 'x', '#111', 0, 0);",
    );
    final base = DateTime.utc(2026, 3, 1);
    await db.transaction(() async {
      for (var i = 0; i < total; i++) {
        // Groups of 10 share a timestamp → ties that the (occurred_at, id) keyset
        // tie-breaker must page through without dup/gap.
        final occurred = dateTimeToSql(base.add(Duration(minutes: i ~/ 10)));
        final id = 'txn-${i.toString().padLeft(4, '0')}';
        await db.customStatement(
          "INSERT INTO transactions(id, amount, currency, account_id, category_id, "
          "type, source, occurred_at, raw_message, parse_confidence, status, "
          "created_at, updated_at, direction) VALUES "
          "('$id', ${10 + i}, 'SAR', 'a0', 'c0', 'payment', 'bank', "
          "'$occurred', 'r$i', 0.9, 'confirmed', '$occurred', '$occurred', 'debit');",
        );
      }
    });
  });
  tearDown(() => db.close());

  test('keyset paging returns every row exactly once, in stable order, bounded',
      () async {
    const pageSize = 100;
    final collected = <String>[];
    final seen = <String>{};
    DateTime? cursorOccurredAt;
    String? cursorId;
    var pages = 0;
    while (true) {
      final page = await repo.confirmedInRangePage(
        from: DateTime.utc(2026, 1, 1),
        to: DateTime.utc(2026, 12, 31),
        beforeOccurredAt: cursorOccurredAt,
        beforeId: cursorId,
        limit: pageSize,
      );
      if (page.isEmpty) break;
      pages++;
      // Bounded retention: a page never exceeds the requested limit.
      expect(page.length, lessThanOrEqualTo(pageSize));
      for (final t in page) {
        expect(seen.add(t.id), isTrue, reason: 'no row appears twice across pages');
        collected.add(t.id);
      }
      if (page.length < pageSize) break;
      cursorOccurredAt = page.last.occurredAt;
      cursorId = page.last.id;
    }

    // Every confirmed row, exactly once.
    expect(collected.length, total);
    expect(seen.length, total);
    expect(pages, (total / pageSize).ceil());

    // Globally sorted (occurred_at DESC, then id DESC) across page boundaries.
    final direct = await repo.confirmedInRangePage(
      from: DateTime.utc(2026, 1, 1),
      to: DateTime.utc(2026, 12, 31),
      limit: total,
    );
    expect(collected, direct.map((t) => t.id).toList(),
        reason: 'paged order == single-shot ordered read (no gap/reorder)');
  });
}
