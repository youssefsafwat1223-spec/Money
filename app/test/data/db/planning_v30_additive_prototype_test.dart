import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/planning_currency_repair.dart';
import 'package:money_companion/domain/finance/decimal_minor.dart';

// MALI-026 (Phase-8 B8-2.7 BLOCKER-2 prototype) — proves the R2 architecture:
// a v30-style ADDITIVE (nullable) planning-column migration opens cleanly on an
// existing dataset WITHOUT any repair manifest (so DB open can never boot-loop),
// and the planning-money cutover is a SEPARATE app-level step gated on the repair
// being satisfied. This exercises the SHAPE only — no schema bump, no real v30
// migration, no _minor columns land in the shipped schema.

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'k';
  @override
  Future<String?> readStoredKey() async => 'k';
}

class _MemoryKv implements RepairKeyValueStore {
  final Map<String, String> _m = {};
  @override
  Future<String?> read(String key) async => _m[key];
  @override
  Future<void> write(String key, String value) async => _m[key] = value;
  @override
  Future<void> delete(String key) async => _m.remove(key);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late String catId;

  setUp(() async {
    db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
    catId = (await db.customSelect('SELECT id FROM categories LIMIT 1;')
            .getSingle())
        .read<String>('id');
    await db.customStatement(
        "INSERT INTO budgets(id, category_id, amount, period, start_date, "
        "is_active) VALUES ('b1', '$catId', 100.0, 'monthly', "
        "'2026-01-01T00:00:00Z', 1);");
    await db.customStatement(
        "INSERT INTO goals(id, name, target_amount, saved_amount, vault_skin, "
        "status, created_at) VALUES ('g1', 'G', 1000.0, 250.0, 'default', "
        "'active', '2026-01-01T00:00:00Z');");
  });
  tearDown(() => db.close());

  // The v30 migration is ADDITIVE ONLY (nullable columns) — the shape that always
  // succeeds and never requires a manifest to open the DB.
  Future<void> applyAdditiveV30Columns() async {
    await db.customStatement('ALTER TABLE budgets ADD COLUMN currency TEXT NULL;');
    await db
        .customStatement('ALTER TABLE budgets ADD COLUMN amount_minor INTEGER NULL;');
    await db.customStatement('ALTER TABLE goals ADD COLUMN currency TEXT NULL;');
    await db.customStatement(
        'ALTER TABLE goals ADD COLUMN target_amount_minor INTEGER NULL;');
    await db.customStatement(
        'ALTER TABLE goals ADD COLUMN saved_amount_minor INTEGER NULL;');
  }

  test('additive v30 columns open cleanly on existing data (no manifest needed)',
      () async {
    await applyAdditiveV30Columns();
    // existing rows survive; the new columns are NULL (inert until cutover).
    final b = await db
        .customSelect(
            "SELECT amount, currency, amount_minor FROM budgets WHERE id='b1';")
        .getSingle();
    expect(b.read<double>('amount'), 100.0);
    expect(b.readNullable<String>('currency'), isNull);
    expect(b.readNullable<int>('amount_minor'), isNull);
  });

  test('planning cutover is gated on repair, then backfills _minor exactly',
      () async {
    await applyAdditiveV30Columns();
    final repair =
        PlanningCurrencyRepairService(db: db, store: _MemoryKv(), installId: 'i');
    // Before repair, the app-level cutover is BLOCKED — never a silent base stamp.
    await expectLater(
        repair.migrationCurrencyForBudget('b1'), throwsA(isA<StateError>()));

    await repair.confirmGlobal('EGP');

    // App-level cutover (one transaction) using ONLY the confirmed currency.
    await db.transaction(() async {
      final bc = await repair.migrationCurrencyForBudget('b1');
      final gc = await repair.migrationCurrencyForGoal('g1');
      await db.customStatement(
          "UPDATE budgets SET currency='$bc', "
          "amount_minor=${legacyRealToMinor(100.0, 2)} WHERE id='b1';");
      await db.customStatement(
          "UPDATE goals SET currency='$gc', "
          "target_amount_minor=${legacyRealToMinor(1000.0, 2)}, "
          "saved_amount_minor=${legacyRealToMinor(250.0, 2)} WHERE id='g1';");
    });

    final b = await db
        .customSelect(
            "SELECT currency, amount_minor FROM budgets WHERE id='b1';")
        .getSingle();
    expect(b.read<String>('currency'), 'EGP');
    expect(b.read<int>('amount_minor'), 10000); // 100.00 EGP exact
    final g = await db
        .customSelect(
            "SELECT currency, target_amount_minor, saved_amount_minor "
            "FROM goals WHERE id='g1';")
        .getSingle();
    expect(g.read<String>('currency'), 'EGP');
    expect(g.read<int>('target_amount_minor'), 100000);
    expect(g.read<int>('saved_amount_minor'), 25000);
  });
}
