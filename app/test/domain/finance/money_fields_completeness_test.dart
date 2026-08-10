import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/domain/finance/money_fields.dart';

// MALI-026 (Phase-8 B8-1.5) — the Strategy-A activation invariant guard. It
// enumerates every REAL column in the LIVE Drift schema (v29) and proves each is
// classified: either a persisted money field (kMoneyFields) or an explicit
// non-money REAL (kNonMoneyRealColumns). A NEW REAL column added without
// classification FAILS this test — so no money field can slip into the schema
// without fixed-precision handling. Schema-derived, not a source grep.

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

void main() {
  test('every REAL schema column is classified money-or-not (no unclassified)',
      () async {
    final db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
    addTearDown(db.close);

    final tables = (await db
            .customSelect(
                "SELECT name FROM sqlite_master WHERE type='table' "
                "AND name NOT LIKE 'sqlite_%';")
            .get())
        .map((r) => r.read<String>('name'))
        .toList();

    final unclassified = <String>[];
    var realColumns = 0;
    for (final table in tables) {
      final cols = await db.customSelect('PRAGMA table_info($table);').get();
      for (final c in cols) {
        final type = (c.readNullable<String>('type') ?? '').toUpperCase();
        if (type != 'REAL') continue;
        realColumns++;
        final name = c.read<String>('name');
        final isMoney = kMoneyFieldByKey.containsKey('$table.$name');
        final isNonMoney = kNonMoneyRealColumns.contains(name);
        if (!isMoney && !isNonMoney) unclassified.add('$table.$name');
      }
    }

    expect(realColumns, greaterThan(0), reason: 'sanity: schema has REAL columns');
    expect(unclassified, isEmpty,
        reason: 'unclassified REAL column(s) — add to kMoneyFields or '
            'kNonMoneyRealColumns: $unclassified');
  });

  test('every registered money field actually exists in the live schema', () async {
    final db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
    addTearDown(db.close);

    for (final f in kMoneyFields) {
      final cols = await db.customSelect('PRAGMA table_info(${f.table});').get();
      final names = cols.map((c) => c.read<String>('name')).toSet();
      expect(names.contains(f.column), isTrue,
          reason: '${f.table}.${f.column} is registered but not in the schema');
    }
  });
}
