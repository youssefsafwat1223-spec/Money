import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/data_portability/data_portability_models.dart';
import 'package:money_companion/core/data_portability/drift_financial_exporter.dart';
import 'package:money_companion/core/data_portability/drift_financial_importer.dart';
import 'package:money_companion/core/data_portability/qirsh_package_codec.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';

/// Audit C-2 (data portability) — a round trip must preserve CANONICAL money.
///
/// Since schema v30 the authority for budget/goal money is the `_minor` integer
/// column plus its currency; the legacy REAL column is a shadow
/// (`kV30MinorColumns`). The export omitted BOTH the `_minor` columns and
/// `currency`, and the import wrote only the REAL column — so exporting your own
/// data and importing it back produced rows with NULL minors.
///
/// That is not cosmetic. `money_codec` throws
/// `MoneyStorageException('v30 read requires a minor value')` on a NULL minor in
/// a canonical database, so the restored budgets and goals screens throw on
/// read: the rows exist and are unreadable. It also leaves the database flagged
/// canonical while holding non-canonical rows, so nothing downstream knows to
/// repair them.
///
/// Written as a genuine round trip rather than a hand-built package, because the
/// defect spanned BOTH halves — a test feeding the importer hand-written CSV
/// containing `amount_minor` would have passed while the real export never
/// emitted that column.
class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

Future<AppDatabase> _database() => AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );

void main() {
  late AppDatabase source;
  late AppDatabase target;

  setUp(() async {
    source = await _database();
    target = await _database();
  });
  tearDown(() async {
    await source.close();
    await target.close();
  });

  Future<String> accountOf(AppDatabase db) async => (await db
          .customSelect(
              'SELECT id FROM accounts ORDER BY is_default DESC LIMIT 1;')
          .getSingle())
      .read<String>('id');

  Future<String> categoryOf(AppDatabase db) async => (await db
          .customSelect("SELECT id FROM categories WHERE key = 'other' LIMIT 1;")
          .getSingle())
      .read<String>('id');

  Future<void> seed() async {
    final accountId = await accountOf(source);
    final categoryId = await categoryOf(source);

    await source.customInsert(
      'INSERT INTO budgets(id,account_id,category_id,currency,amount,'
      'amount_minor,period,start_date,is_active,last_notified_spent_amount,'
      'last_notified_spent_amount_minor,show_on_header) '
      "VALUES('b-1',?,?,'SAR',250.75,25075,'monthly','2026-01-01T00:00:00.000Z',"
      '1,0.0,0,0);',
      variables: [Variable(accountId), Variable(categoryId)],
    );

    await source.customInsert(
      'INSERT INTO goals(id,account_id,name,currency,target_amount,'
      'target_amount_minor,saved_amount,saved_amount_minor,status,vault_skin,'
      'created_at) '
      "VALUES('g-1',?,'Trip','SAR',1000.00,100000,250.50,25050,'active',"
      "'classic','2026-01-01T00:00:00.000Z');",
      variables: [Variable(accountId)],
    );

    await backfillNonPlanningMoneyV30(source);
  }

  Future<void> roundTrip() async {
    final bytes =
        (await DriftFinancialExporter(source).exportFinancialPackage()).bytes;
    final package = decodeQirshPackage(bytes);
    await DriftFinancialImporter(target)
        .importPackage(package, ImportMode.merge);
  }

  test('a budget survives export→import with its canonical minor and currency',
      () async {
    await seed();
    await roundTrip();

    final row = await target
        .customSelect("SELECT * FROM budgets WHERE id = 'b-1';")
        .getSingle();

    expect(row.readNullable<int>('amount_minor'), 25075,
        reason: 'the canonical authority must survive the round trip — a NULL '
            'minor makes every planning read throw');
    expect(row.readNullable<String>('currency'), 'SAR',
        reason: 'minor units are meaningless without their currency scale');
  });

  test('a goal survives with every canonical money column intact', () async {
    await seed();
    await roundTrip();

    final row = await target
        .customSelect("SELECT * FROM goals WHERE id = 'g-1';")
        .getSingle();

    expect(row.readNullable<int>('target_amount_minor'), 100000);
    expect(row.readNullable<int>('saved_amount_minor'), 25050);
    expect(row.readNullable<String>('currency'), 'SAR');
  });

  test('wherever a money VALUE exists, its canonical minor exists too',
      () async {
    // Checked against the canonical column registry rather than a hand-listed
    // set, so a canonical column added later is covered automatically instead
    // of being silently missed.
    //
    // The invariant is deliberately NOT "no minor is ever NULL". Writing it
    // that way failed on `goals.auto_save_amount_minor`, which is legitimately
    // NULL when the user has configured no auto-save — an absent amount, not a
    // lost one. The property that actually matters is that the canonical
    // authority exists wherever a VALUE exists: a non-NULL legacy REAL column
    // with a NULL minor is the corruption, because that is the row money_codec
    // will throw on.
    await seed();
    await roundTrip();

    for (final col in kV30MinorColumns) {
      if (!const ['budgets', 'goals'].contains(col.table)) continue;
      final legacy = col.minorColumn.substring(
          0, col.minorColumn.length - '_minor'.length);
      final orphans = await target
          .customSelect(
            'SELECT COUNT(*) AS c FROM ${col.table} '
            'WHERE $legacy IS NOT NULL AND ${col.minorColumn} IS NULL '
            'AND deleted_at IS NULL;',
          )
          .getSingle();
      expect(orphans.read<int>('c'), 0,
          reason: '${col.table} has a row with $legacy set but '
              '${col.minorColumn} NULL — the canonical authority was lost in '
              'the round trip, and money_codec throws on that row');
    }
  });

  test('the exported package actually carries the canonical columns', () async {
    // The import half cannot be correct if the export never emitted the data.
    // Asserted on the package itself so a regression is attributed to the right
    // side of the round trip.
    await seed();
    final bytes =
        (await DriftFinancialExporter(source).exportFinancialPackage()).bytes;
    final package = decodeQirshPackage(bytes);

    for (final entry in const {
      'budgets': ['currency', 'amount_minor'],
      'goals': ['currency', 'target_amount_minor', 'saved_amount_minor'],
    }.entries) {
      final headers = package.tables[entry.key]!.headers;
      for (final col in entry.value) {
        expect(headers, contains(col),
            reason: '${entry.key}.csv must export $col — without it the '
                'importer has no authority to reconstruct canonical money');
      }
    }
  });

  test('the round trip preserves the exact value, not an approximation',
      () async {
    // Money equality is the point: a value re-derived through a double could
    // differ in the last place and silently change what the user budgeted.
    await seed();
    await roundTrip();

    final src = await source
        .customSelect("SELECT amount_minor FROM budgets WHERE id = 'b-1';")
        .getSingle();
    final dst = await target
        .customSelect("SELECT amount_minor FROM budgets WHERE id = 'b-1';")
        .getSingle();
    expect(dst.readNullable<int>('amount_minor'),
        src.readNullable<int>('amount_minor'));
  });
}
