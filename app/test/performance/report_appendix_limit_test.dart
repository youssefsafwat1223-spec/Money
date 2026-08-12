// Phase-7 Batch-2-B closure §Blocker-3 — the detailed report appendix is never
// SILENTLY truncated. At/under the 5000-row bound it is complete; above it the
// appendix is OMITTED (empty + explicit flag) so a 5001-row period never produces a
// report that looks complete while dropping a transaction. Summary/aggregates stay
// correct (separate SQL).
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';
import 'package:money_companion/data/db/sql_value_codec.dart';
import 'package:money_companion/data/reporting/report_snapshot_builder.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_category_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/reporting/report_data_snapshot.dart';
import 'package:money_companion/domain/reporting/report_request.dart';

class _K implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'k';
  @override
  Future<String?> readStoredKey() async => 'k';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;

  Future<ReportDataSnapshot> generateWith(int count) async {
    db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _K());
    await db.customStatement(
      "INSERT INTO accounts(id, name, currency, type, created_at, updated_at) "
      "VALUES ('a0', 'A', 'SAR', 'bank', '2026-06-01', '2026-06-01');",
    );
    final base = DateTime.utc(2026, 6, 2);
    await db.transaction(() async {
      for (var i = 0; i < count; i++) {
        final occ = dateTimeToSql(base.add(Duration(seconds: i)));
        await db.customStatement(
          "INSERT INTO transactions(id, amount, currency, account_id, type, source, "
          "occurred_at, raw_message, parse_confidence, status, created_at, "
          "updated_at) VALUES ('t${i.toString().padLeft(6, '0')}', ${10 + i}, "
          "'SAR', 'a0', 'payment', 'bank', '$occ', 'r', 0.9, 'confirmed', "
          "'$occ', '$occ');",
        );
      }
    });
    await backfillNonPlanningMoneyV30(db);
    final builder = ReportSnapshotBuilder(
      transactions: DriftTransactionRepository(db),
      accounts: DriftAccountRepository(db),
      categories: DriftCategoryRepository(db),
      clock: () => DateTime(2026, 6, 15, 12), // MonthlyPeriod = June 2026
    );
    return builder.build(const ReportRequest(
      period: MonthlyPeriod(),
      content: ReportContentOptions(includeTransactionDetails: true),
    ));
  }

  tearDown(() => db.close());

  test('4999 rows → full appendix, not omitted', () async {
    final s = await generateWith(4999);
    expect(s.appendixOmittedForSize, isFalse);
    expect(s.appendixTransactions, hasLength(4999));
  });

  test('exactly 5000 rows → full appendix, not omitted', () async {
    final s = await generateWith(5000);
    expect(s.appendixOmittedForSize, isFalse);
    expect(s.appendixTransactions, hasLength(5000));
  });

  test('5001 rows → appendix OMITTED (never a silent truncation)', () async {
    final s = await generateWith(5001);
    expect(s.appendixOmittedForSize, isTrue);
    expect(s.appendixTransactions, isEmpty,
        reason: 'not a truncated 5000-row list masquerading as complete');
    expect(s.appendixRowLimit, 5000);
  });

  test('much larger dataset (8000) → still omitted, bounded (no full load)',
      () async {
    final s = await generateWith(8000);
    expect(s.appendixOmittedForSize, isTrue);
    expect(s.appendixTransactions, isEmpty);
  });
}
