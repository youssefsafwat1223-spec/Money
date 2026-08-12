import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/planning_canonical_invariants.dart';
import 'package:money_companion/data/db/planning_currency_repair.dart';
import 'package:money_companion/data/db/planning_cutover.dart';
import 'package:money_companion/data/db/planning_cutover_executor.dart';
import 'package:money_companion/data/repositories/drift_budget_repository.dart';
import 'package:money_companion/data/repositories/drift_goal_repository.dart';
import 'package:money_companion/domain/entities/budget_entity.dart';
import 'package:money_companion/domain/entities/goal_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/finance/planning_mutation_guard.dart';

// MALI-026 (Phase-8 B8-3 §11/§12/§13) — the primary 3b integration: a real
// upgraded-v29-with-planning DB → unresolved (P1) → canonical repo reads/writes
// refuse → repair → P2 executor → recompute → canonical (P3) → exact minor Money;
// plus fresh-v30 canonical, and existing-row currency immutability under a base
// currency change.

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

  DbBackedPlanningCutoverCoordinator coordinator(PlanningCutoverState initial) =>
      DbBackedPlanningCutoverCoordinator(
        initialState: initial,
        readUserVersion: () async => (await db
                .customSelect('PRAGMA user_version;')
                .getSingle())
            .read<int>('user_version'),
        readMarker: () async => (await db
                .customSelect(
                    'SELECT planning_cutover_state AS s FROM user_settings;')
                .getSingle())
            .read<int>('s'),
        countCanonicalViolations: () async =>
            (await planningCanonicalViolations(db)).length,
      );

  setUp(() async {
    db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
    catId = (await db.customSelect('SELECT id FROM categories LIMIT 1;')
            .getSingle())
        .read<String>('id');
  });
  tearDown(() => db.close());

  test('§13 upgraded v29-with-planning → unresolved → repair → P2 → P3 exact',
      () async {
    // A legacy planning row (REAL amount, NULL currency/minor).
    await db.customStatement(
      "INSERT INTO budgets(id, category_id, amount, period, start_date, "
      "is_active, last_notified_spent_amount) VALUES ('b1', '$catId', 100.0, "
      "'monthly', '2026-01-01T00:00:00Z', 1, 0.0);",
    );
    // Simulate a pre-v30 upgrade landing with the planning row present.
    await db.customStatement(
        'UPDATE user_settings SET planning_cutover_state = 0;');
    await db.customStatement('PRAGMA user_version = 29;');
    await db.debugReinitialize();

    // Coordinator resolves UNRESOLVED (P1).
    final coord = coordinator(PlanningCutoverState.unresolved);
    expect(await coord.refreshFromDatabase(), PlanningCutoverState.unresolved);

    // P1: canonical repo reads AND writes refuse.
    final p1Repo = DriftBudgetRepository(db, coordinator: coord);
    await expectLater(
        p1Repo.getAll(), throwsA(isA<PlanningCurrencyRepairRequired>()));
    await expectLater(
      p1Repo.save(BudgetEntity(
        id: 'b2',
        categoryId: catId,
        currency: 'EGP',
        amountMoney: Money.parse('5', 'EGP'),
        lastNotifiedSpentMoney: Money(0, 'EGP'),
        period: BudgetPeriod.monthly,
        startDate: DateTime.utc(2026, 1, 1),
        isActive: true,
        lastNotifiedPeriodStart: DateTime.utc(2026, 1, 1),
      )),
      throwsA(isA<PlanningCurrencyRepairRequired>()),
    );

    // Repair + cutover.
    final repair = PlanningCurrencyRepairService(
        db: db, store: _MemoryKv(), installId: 'i', userId: 'u');
    await repair.confirmGlobal('EGP');
    await PlanningCutoverExecutor(db, repair).execute();

    // Recompute → CANONICAL (P3).
    expect(await coord.refreshFromDatabase(), PlanningCutoverState.canonical);

    // P3: canonical repo reads exact minor Money from row.currency + _minor.
    final p3Repo = DriftBudgetRepository(db, coordinator: coord);
    final budgets = await p3Repo.getAll();
    expect(budgets.single.currency, 'EGP');
    expect(budgets.single.amountMoney.minorUnits, 10000); // 100.00 EGP
  });

  test('§12 fresh v30 install → canonical, planning creation allowed immediately',
      () async {
    // Fresh DB (no planning rows) → migration set the marker canonical.
    final coord = coordinator(PlanningCutoverState.canonical);
    expect(await coord.refreshFromDatabase(), PlanningCutoverState.canonical);
    final repo = DriftBudgetRepository(db, coordinator: coord);
    await repo.save(BudgetEntity(
      id: 'b1',
      categoryId: catId,
      currency: 'SAR',
      amountMoney: Money.parse('300', 'SAR'),
      lastNotifiedSpentMoney: Money(0, 'SAR'),
      period: BudgetPeriod.monthly,
      startDate: DateTime.utc(2026, 1, 1),
      isActive: true,
      lastNotifiedPeriodStart: DateTime.utc(2026, 1, 1),
    ));
    expect((await repo.getAll()).single.amountMoney.minorUnits, 30000);
    expect(await planningCanonicalViolations(db), isEmpty);
  });

  test('§11 existing-row currency is immutable under a base-currency change',
      () async {
    final coord = coordinator(PlanningCutoverState.canonical);
    final budgetRepo = DriftBudgetRepository(db, coordinator: coord);
    final goalRepo = DriftGoalRepository(db, coordinator: coord);
    await budgetRepo.save(BudgetEntity(
      id: 'b1',
      categoryId: catId,
      currency: 'EGP',
      amountMoney: Money.parse('100', 'EGP'),
      lastNotifiedSpentMoney: Money(0, 'EGP'),
      period: BudgetPeriod.monthly,
      startDate: DateTime.utc(2026, 1, 1),
      isActive: true,
      lastNotifiedPeriodStart: DateTime.utc(2026, 1, 1),
    ));
    await goalRepo.save(GoalEntity(
      id: 'g1',
      name: 'Trip',
      currency: 'EGP',
      targetMoney: Money.parse('1000', 'EGP'),
      savedMoney: Money.parse('250', 'EGP'),
      lastNotifiedSavedMoney: Money(0, 'EGP'),
      vaultSkin: 'default',
      status: 'active',
      createdAt: DateTime.utc(2026, 1, 1),
    ));

    // "Change the effective base to KWD."
    await db.customStatement("UPDATE user_settings SET currency = 'KWD';");

    // Reload: currency + minor are the persisted EGP facts, unchanged.
    final b = (await budgetRepo.getAll()).single;
    expect(b.currency, 'EGP');
    expect(b.amountMoney.minorUnits, 10000);
    final g = (await goalRepo.getAll()).single;
    expect(g.currency, 'EGP');
    expect(g.targetMoney.minorUnits, 100000);

    // Editing a NON-money field must not change the currency (repo rejects a
    // currency change on update; here we keep it EGP and edit the period).
    await budgetRepo.save(b.copyWith(period: BudgetPeriod.weekly));
    final b2 = (await budgetRepo.getAll()).single;
    expect(b2.currency, 'EGP');
    expect(b2.amountMoney.minorUnits, 10000);
    expect(b2.period, BudgetPeriod.weekly);
  });

  test('§10/correction 5 a currency change on UPDATE is rejected', () async {
    final coord = coordinator(PlanningCutoverState.canonical);
    final repo = DriftBudgetRepository(db, coordinator: coord);
    final b = BudgetEntity(
      id: 'b1',
      categoryId: catId,
      currency: 'EGP',
      amountMoney: Money.parse('100', 'EGP'),
      lastNotifiedSpentMoney: Money(0, 'EGP'),
      period: BudgetPeriod.monthly,
      startDate: DateTime.utc(2026, 1, 1),
      isActive: true,
      lastNotifiedPeriodStart: DateTime.utc(2026, 1, 1),
    );
    await repo.save(b);
    // Attempt to flip the currency to KWD on update → rejected.
    await expectLater(
      repo.save(b.copyWith(
          currency: 'KWD', amountMoney: Money.parse('100', 'KWD'))),
      throwsA(isA<StateError>()),
    );
  });
}
