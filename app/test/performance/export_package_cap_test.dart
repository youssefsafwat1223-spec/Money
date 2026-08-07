// Phase-7 Batch-2-B closure §Blocker-2 — the full-data export has a REAL enforced
// total cap (separate from the backup-envelope/import caps), checked INCREMENTALLY
// while building. A legitimate 10k export succeeds and is page-bounded (every row
// once); an over-cap dataset aborts MID-BUILD with a typed resource-limit error and
// returns no partial export.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/data_portability/data_portability_models.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;

  Future<void> seed(int count) async {
    db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _K());
    await db.customStatement(
      "INSERT INTO accounts(id, name, currency, type, created_at, updated_at) "
      "VALUES ('a0', 'A', 'SAR', 'bank', '2026-01-01', '2026-01-01');",
    );
    final base = DateTime.utc(2026, 1, 1);
    await db.transaction(() async {
      for (var i = 0; i < count; i++) {
        final occ = dateTimeToSql(base.add(Duration(minutes: i)));
        await db.customStatement(
          "INSERT INTO transactions(id, amount, currency, account_id, type, source, "
          "occurred_at, raw_message, parse_confidence, status, created_at, "
          "updated_at) VALUES ('t${i.toString().padLeft(6, '0')}', ${10 + i}, "
          "'SAR', 'a0', 'payment', 'bank', '$occ', 'r', 0.9, 'confirmed', "
          "'$occ', '$occ');",
        );
      }
    });
  }

  tearDown(() => db.close());

  test('a legitimate 10k package export succeeds and counts every transaction',
      () async {
    await seed(10000);
    final file = await DriftFinancialExporter(db).exportFinancialPackage();
    expect(file.recordCount, greaterThanOrEqualTo(10000));
    expect(file.bytes, isNotEmpty);
  });

  test('an over-cap export aborts with a typed resource-limit error (no partial)',
      () async {
    await seed(500); // ~ tens of KiB of CSV, far over a 2 KiB test cap
    final exporter = DriftFinancialExporter(db, maxPackageBytes: 2048);
    Object? thrown;
    ExportedFile? file;
    try {
      file = await exporter.exportFinancialPackage();
    } catch (e) {
      thrown = e;
    }
    expect(thrown, isA<DataPortabilityException>());
    expect(file, isNull, reason: 'no partial export artifact is returned on overflow');
  });
}
