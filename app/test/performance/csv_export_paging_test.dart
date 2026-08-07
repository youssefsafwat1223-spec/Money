// Phase-7 Batch-2 §MALI-030 — the CSV export pages the transaction table in bounded
// keyset chunks: a 10k export issues MANY bounded SELECTs (never one unbounded
// full-table read), emits every row exactly once, and preserves ordering.
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/data_portability/drift_financial_exporter.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/sql_value_codec.dart';

class _K implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'k';
  @override
  Future<String?> readStoredKey() async => 'k';
}

/// Counts SELECTs against the transactions table (a paged export issues several
/// bounded ones; the old full-table export issued exactly one).
class _TxnSelectCounter extends QueryInterceptor {
  int txnSelects = 0;
  int maxRowsPerSelect = 0;

  @override
  Future<List<Map<String, Object?>>> runSelect(
      QueryExecutor e, String statement, List<Object?> args) async {
    final isTxnPage = statement.toLowerCase().contains('from transactions t');
    final result = await super.runSelect(e, statement, args);
    if (isTxnPage) {
      txnSelects++;
      if (result.length > maxRowsPerSelect) maxRowsPerSelect = result.length;
    }
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('10k CSV export is paged (many bounded reads) and emits every row', () async {
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
    await db.customStatement(
      "INSERT INTO categories(id, key, name_ar, icon, color, is_income, sort_order) "
      "VALUES ('c0', 'k0', 'ف', 'x', '#111', 0, 0);",
    );
    final base = DateTime.utc(2026, 1, 1);
    const total = 10000;
    await db.transaction(() async {
      for (var i = 0; i < total; i++) {
        final occ = dateTimeToSql(base.add(Duration(minutes: i)));
        final id = 'txn-${i.toString().padLeft(5, '0')}';
        await db.customStatement(
          "INSERT INTO transactions(id, amount, currency, account_id, category_id, "
          "type, source, occurred_at, raw_message, parse_confidence, status, "
          "created_at, updated_at, direction) VALUES "
          "('$id', ${10 + i}, 'SAR', 'a0', 'c0', 'payment', 'bank', "
          "'$occ', 'r$i', 0.9, 'confirmed', '$occ', '$occ', 'debit');",
        );
      }
    });
    counter.txnSelects = 0;
    counter.maxRowsPerSelect = 0;

    final file = await DriftFinancialExporter(db).exportTransactionsCsv();

    // Every row exported exactly once.
    expect(file.recordCount, total);
    // Paged: multiple bounded reads, none returning the whole table.
    expect(counter.txnSelects, greaterThan(1),
        reason: '10k export must page, not one full-table SELECT');
    expect(counter.maxRowsPerSelect, lessThanOrEqualTo(1000),
        reason: 'each page retains at most the bounded page size');
    // CSV body: header + one line per row (BOM on the header line).
    final text = String.fromCharCodes(file.bytes);
    final lines = text.split('\r\n').where((l) => l.trim().isNotEmpty).toList();
    expect(lines.length, total + 1); // header + rows
    expect(lines.first, contains('record_id'));
    expect(lines[1], contains('txn-00000')); // first row (occurred_at ASC)
    expect(lines.last, contains('txn-09999')); // last row
  });
}
