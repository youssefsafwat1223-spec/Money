// Phase-7 Batch-2 §MALI-030 — the backup snapshot reads the usage-scaling
// transactions table in bounded keyset pages (never one full-table read), while
// still capturing every backup-safe row. Excluded tables (restore journal) stay out.
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backup/backup_snapshot_builder.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/sql_value_codec.dart';

class _K implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'k';
  @override
  Future<String?> readStoredKey() async => 'k';
}

class _TxnSelectCounter extends QueryInterceptor {
  int txnSelects = 0;
  int maxRows = 0;

  @override
  Future<List<Map<String, Object?>>> runSelect(
      QueryExecutor e, String statement, List<Object?> args) async {
    final isTxn = RegExp(r'from\s+transactions', caseSensitive: false)
        .hasMatch(statement);
    final result = await super.runSelect(e, statement, args);
    if (isTxn) {
      txnSelects++;
      if (result.length > maxRows) maxRows = result.length;
    }
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('snapshot pages the transactions table yet captures every row', () async {
    final counter = _TxnSelectCounter();
    final db = await AppDatabase.open(
      executor: NativeDatabase.memory().interceptWith(counter),
      keyStore: _K(),
    );
    addTearDown(db.close);
    await db.customStatement(
      "INSERT INTO accounts(id, name, currency, type, created_at, updated_at) "
      "VALUES ('a0', 'A', 'SAR', 'bank', '2026-01-01', '2026-01-01');",
    );
    const total = 10000;
    final base = DateTime.utc(2026, 1, 1);
    await db.transaction(() async {
      for (var i = 0; i < total; i++) {
        final occ = dateTimeToSql(base.add(Duration(minutes: i)));
        await db.customStatement(
          "INSERT INTO transactions(id, amount, currency, account_id, type, "
          "source, occurred_at, raw_message, parse_confidence, status, "
          "created_at, updated_at) VALUES "
          "('txn-${i.toString().padLeft(5, '0')}', ${10 + i}, 'SAR', 'a0', "
          "'payment', 'bank', '$occ', 'r$i', 0.9, 'confirmed', '$occ', '$occ');",
        );
      }
    });
    counter.txnSelects = 0;
    counter.maxRows = 0;

    final snapshot = await BackupSnapshotBuilder(db).build();

    final txns = (snapshot['tables'] as Map)['transactions'] as List;
    // Every row captured.
    expect(txns.length, total);
    // Paged: multiple bounded reads, none returning the whole table.
    expect(counter.txnSelects, greaterThan(1),
        reason: 'the snapshot must page the transactions table, not one big read');
    expect(counter.maxRows, lessThanOrEqualTo(2000),
        reason: 'each page holds at most the bounded snapshot page size');
    // Excluded table never appears.
    expect((snapshot['tables'] as Map).containsKey('restore_operations'), isFalse);
  });
}
