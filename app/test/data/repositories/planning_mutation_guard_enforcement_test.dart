import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/planning_cutover.dart';
import 'package:money_companion/data/repositories/drift_budget_repository.dart';
import 'package:money_companion/data/repositories/drift_goal_repository.dart';
import 'package:money_companion/domain/entities/budget_entity.dart';
import 'package:money_companion/domain/entities/goal_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/finance/planning_mutation_guard.dart';

// MALI-026 (Phase-8 B8-2.10 §1/§2) — the PlanningMutationGuard is wired into the
// REAL planning repositories (not a test wrapper). These tests drive the actual
// DriftBudgetRepository / DriftGoalRepository against an in-memory database and
// prove, per required-proof:
//   inject coordinator = unresolved -> real repo mutation throws the typed
//     PlanningCurrencyRepairRequired AND the database is unchanged;
//   coordinator = canonical (v30 P3) -> the mutation proceeds unchanged.

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';
  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

const _unresolved =
    FixedPlanningCutoverCoordinator(PlanningCutoverState.unresolved);
const _canonical =
    FixedPlanningCutoverCoordinator(PlanningCutoverState.canonical);

BudgetEntity _budget(String id) => BudgetEntity(
      id: id,
      categoryId: 'cat-1',
      currency: 'SAR',
      amountMoney: Money.parse('250.0', 'SAR'),
      period: BudgetPeriod.monthly,
      startDate: DateTime.utc(2026, 1, 1),
      isActive: true,
      lastNotifiedSpentMoney: Money(0, 'SAR'),
      lastNotifiedPeriodStart: DateTime.utc(2026, 1, 1),
    );

GoalEntity _goal(String id) => GoalEntity(
      id: id,
      name: 'Trip',
      currency: 'SAR',
      targetMoney: Money.parse('1000.0', 'SAR'),
      savedMoney: Money.parse('100.0', 'SAR'),
      lastNotifiedSavedMoney: Money(0, 'SAR'),
      vaultSkin: 'default',
      status: 'active',
      createdAt: DateTime.utc(2026, 1, 1),
    );

GoalContributionEntity _contribution(String id, String goalId) =>
    GoalContributionEntity(
      id: id,
      goalId: goalId,
      amountMoney: Money.parse('50.0', 'SAR'),
      createdAt: DateTime.utc(2026, 2, 1),
    );

void main() {
  late AppDatabase db;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    // budgets.category_id is a FK → seed the referenced category.
    await db.customStatement('''
      INSERT INTO categories(id, key, name_ar, icon, color, is_income, sort_order)
      VALUES ('cat-1', 'cat_1', 'فئة', 'icon', '#fff', 0, 0);
    ''');
  });

  tearDown(() async => db.close());

  Future<int> count(String table) async {
    final row =
        await db.customSelect('SELECT COUNT(*) AS n FROM $table;').getSingle();
    return row.read<int>('n');
  }

  Future<double?> goalSaved(String id) async {
    final row = await db.customSelect(
      'SELECT saved_amount AS s FROM goals WHERE id = ?;',
      variables: [Variable.withString(id)],
    ).getSingleOrNull();
    return row?.read<double>('s');
  }

  Future<bool> isBudgetDeleted(String id) async {
    final row = await db.customSelect(
      'SELECT deleted_at AS d FROM budgets WHERE id = ?;',
      variables: [Variable.withString(id)],
    ).getSingleOrNull();
    return row?.read<String?>('d') != null;
  }

  group('unresolved coordinator blocks the real planning repositories', () {
    test('budget save throws and writes nothing', () async {
      final repo = DriftBudgetRepository(db, coordinator: _unresolved);
      await expectLater(
        () => repo.save(_budget('b1')),
        throwsA(isA<PlanningCurrencyRepairRequired>()),
      );
      expect(await count('budgets'), 0);
    });

    test('budget delete throws and leaves the row intact', () async {
      // Seed a live budget through the canonical coordinator.
      await DriftBudgetRepository(db, coordinator: _canonical)
          .save(_budget('b1'));
      final repo = DriftBudgetRepository(db, coordinator: _unresolved);
      await expectLater(
        () => repo.delete('b1'),
        throwsA(isA<PlanningCurrencyRepairRequired>()),
      );
      expect(await isBudgetDeleted('b1'), isFalse);
    });

    test('goal save throws and writes nothing', () async {
      final repo = DriftGoalRepository(db, coordinator: _unresolved);
      await expectLater(
        () => repo.save(_goal('g1')),
        throwsA(isA<PlanningCurrencyRepairRequired>()),
      );
      expect(await count('goals'), 0);
    });

    test('goal delete throws', () async {
      await DriftGoalRepository(db, coordinator: _canonical).save(_goal('g1'));
      final repo = DriftGoalRepository(db, coordinator: _unresolved);
      await expectLater(
        () => repo.delete('g1'),
        throwsA(isA<PlanningCurrencyRepairRequired>()),
      );
    });

    test('addContribution throws, inserts no contribution, saved_amount intact',
        () async {
      await DriftGoalRepository(db, coordinator: _canonical).save(_goal('g1'));
      final repo = DriftGoalRepository(db, coordinator: _unresolved);
      await expectLater(
        () => repo.addContribution(_contribution('c1', 'g1')),
        throwsA(isA<PlanningCurrencyRepairRequired>()),
      );
      expect(await count('goal_contributions'), 0);
      expect(await goalSaved('g1'), 100.0); // unchanged (was 100 from seed)
    });
  });

  group('canonical coordinator (v30 P3) — writes and reads proceed', () {
    test('budget save + delete proceed', () async {
      final repo = DriftBudgetRepository(db, coordinator: _canonical);
      await repo.save(_budget('b1'));
      expect(await count('budgets'), 1);
      await repo.delete('b1');
      expect(await isBudgetDeleted('b1'), isTrue);
    });

    test('goal save + addContribution proceed and update saved_amount',
        () async {
      final repo = DriftGoalRepository(db, coordinator: _canonical);
      await repo.save(_goal('g1'));
      await repo.addContribution(_contribution('c1', 'g1'));
      expect(await count('goal_contributions'), 1);
      expect(await goalSaved('g1'), 150.0); // 100 + 50
    });

    test(
        'the DEFAULT repository coordinator resolves to canonical (no injection needed)',
        () async {
      // Proves production construction sites that pass no guard are unaffected.
      final repo = DriftBudgetRepository(db);
      await repo.save(_budget('b2'));
      expect(await count('budgets'), 1);
    });
  });
}
