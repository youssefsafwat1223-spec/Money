import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/planning_currency_repair.dart';
import 'package:money_companion/data/db/planning_cutover.dart';
import 'package:money_companion/data/db/planning_cutover_executor.dart';

// MALI-026 (Phase-8 B8-3 §10/§13/§14/§4/§36) — the DB-marker coordinator state
// machine + the P2 planning cutover executor (atomic, gated on a satisfied
// repair, exact postflight, all-or-nothing with the durable marker).

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
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

  group('§10 computePlanningCutoverState', () {
    test('userVersion < 30 → legacy', () async {
      expect(
        await computePlanningCutoverState(
            () async => 29, () async => 0, () async => 0),
        PlanningCutoverState.legacy,
      );
    });
    test('v30 + marker 0 → unresolved', () async {
      expect(
        await computePlanningCutoverState(
            () async => 30, () async => 0, () async => 5),
        PlanningCutoverState.unresolved,
      );
    });
    test('v30 + marker 1 + no violations → canonical', () async {
      expect(
        await computePlanningCutoverState(
            () async => 30, () async => 1, () async => 0),
        PlanningCutoverState.canonical,
      );
    });
    test('v30 + marker 1 + violations → invariant failure (not canonical)',
        () async {
      await expectLater(
        computePlanningCutoverState(
            () async => 30, () async => 1, () async => 3),
        throwsA(isA<PlanningCutoverInvariantException>()),
      );
    });
  });

  group('P2 executor', () {
    late AppDatabase db;
    late _MemoryKv store;
    late String catId;
    late PlanningCurrencyRepairService repair;

    Future<void> addBudget(String id, double amount) => db.customStatement(
          "INSERT INTO budgets(id, category_id, amount, period, start_date, "
          "is_active, last_notified_spent_amount) VALUES ('$id', '$catId', "
          "$amount, 'monthly', '2026-01-01T00:00:00Z', 1, 0.0);",
        );
    Future<void> addGoal(String id) => db.customStatement(
          "INSERT INTO goals(id, name, target_amount, saved_amount, vault_skin, "
          "status, created_at, last_notified_saved_amount) VALUES ('$id', 'G', "
          "1000.0, 250.0, 'default', 'active', '2026-01-01T00:00:00Z', 0.0);",
        );
    Future<void> addContribution(String id, String goalId) =>
        db.customStatement(
          "INSERT INTO goal_contributions(id, goal_id, amount, created_at) "
          "VALUES ('$id', '$goalId', 50.0, '2026-02-01T00:00:00Z');",
        );

    Future<int> marker() async => (await db
            .customSelect('SELECT planning_cutover_state AS s FROM user_settings;')
            .getSingle())
        .read<int>('s');
    Future<int?> minor(String table, String col, String id) async => (await db
            .customSelect("SELECT $col AS m FROM $table WHERE id = '$id';")
            .getSingle())
        .readNullable<int>('m');
    Future<String?> currencyOf(String table, String id) async => (await db
            .customSelect("SELECT currency AS c FROM $table WHERE id = '$id';")
            .getSingle())
        .readNullable<String>('c');

    setUp(() async {
      store = _MemoryKv();
      db = await AppDatabase.open(
          executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
      catId = (await db.customSelect('SELECT id FROM categories LIMIT 1;')
              .getSingle())
          .read<String>('id');
      repair = PlanningCurrencyRepairService(
          db: db, store: store, installId: 'i', userId: 'u');
      // Fresh DB seeded the marker canonical (empty). Reset to unresolved for the
      // with-data cutover tests.
      await db.customStatement(
          'UPDATE user_settings SET planning_cutover_state = 0;');
    });
    tearDown(() => db.close());

    test('§13 satisfied → converts budget/goal/contribution + marker canonical',
        () async {
      await addBudget('b1', 100.0);
      await addGoal('g1');
      await addContribution('c1', 'g1');
      await repair.confirmGlobal('EGP'); // 2-dec

      final state = await PlanningCutoverExecutor(db, repair).execute();
      expect(state, PlanningCutoverState.canonical);
      expect(await marker(), 1);
      expect(await currencyOf('budgets', 'b1'), 'EGP');
      expect(await minor('budgets', 'amount_minor', 'b1'), 10000);
      expect(await currencyOf('goals', 'g1'), 'EGP');
      expect(await minor('goals', 'target_amount_minor', 'g1'), 100000);
      expect(await minor('goals', 'saved_amount_minor', 'g1'), 25000);
      // contribution inherits parent goal currency (EGP)
      expect(await minor('goal_contributions', 'amount_minor', 'c1'), 5000);
    });

    test('§13.2/§4 refuses when repair not satisfied (nothing mutated)',
        () async {
      await addBudget('b1', 100.0); // needsConfirmation (no manifest)
      await expectLater(
        PlanningCutoverExecutor(db, repair).execute(),
        throwsA(isA<PlanningCutoverRefused>()),
      );
      expect(await marker(), 0);
      expect(await minor('budgets', 'amount_minor', 'b1'), isNull);
      expect(await currencyOf('budgets', 'b1'), isNull);
    });

    test('§4 refuses when the confirmed dataset went stale', () async {
      await addBudget('b1', 100.0);
      await repair.confirmGlobal('EGP');
      await addBudget('b2', 200.0); // dataset changed → stale
      await expectLater(
        PlanningCutoverExecutor(db, repair).execute(),
        throwsA(isA<PlanningCutoverRefused>()),
      );
      expect(await marker(), 0);
    });

    test('§36 a failure mid-cutover rolls back money AND marker (still P1)',
        () async {
      await addBudget('b1', 100.0);
      await addBudget('b_huge', 1e19); // overflows int64 minor mid-transaction
      await repair.confirmGlobal('EGP');
      await expectLater(
        PlanningCutoverExecutor(db, repair).execute(),
        throwsA(anything),
      );
      // All-or-nothing: marker unresolved, NO budget converted.
      expect(await marker(), 0);
      expect(await minor('budgets', 'amount_minor', 'b1'), isNull);
      expect(await currencyOf('budgets', 'b1'), isNull);
    });

    test('§11 notRequired (no planning rows) → marker canonical, idempotent',
        () async {
      final state = await PlanningCutoverExecutor(db, repair).execute();
      expect(state, PlanningCutoverState.canonical);
      expect(await marker(), 1);
    });
  });
}
