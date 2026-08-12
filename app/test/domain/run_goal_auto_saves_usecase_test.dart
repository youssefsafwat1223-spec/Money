import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_goal_repository.dart';
import 'package:money_companion/domain/entities/goal_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/usecases/run_goal_auto_saves_usecase.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';
  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

void main() {
  late AppDatabase db;
  late DriftGoalRepository repo;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    repo = DriftGoalRepository(db);
  });

  tearDown(() async => db.close());

  GoalEntity goal({
    double? autoAmount,
    String? period,
    DateTime? lastRun,
    String status = 'active',
  }) =>
      GoalEntity(
        id: 'g1',
        name: 'سيارة',
        currency: 'SAR',
        targetMoney: Money.parse('10000', 'SAR'),
        savedMoney: Money(0, 'SAR'),
        lastNotifiedSavedMoney: Money(0, 'SAR'),
        vaultSkin: 'default_vault',
        status: status,
        createdAt: DateTime.utc(2026, 1, 1),
        autoSaveMoney:
            autoAmount == null ? null : Money.fromLegacyReal(autoAmount, 'SAR'),
        autoSavePeriod: period,
        autoSaveLastRun: lastRun,
      );

  test('adds one monthly contribution when one period is due', () async {
    final lastRun = DateTime.now().subtract(const Duration(days: 32));
    await repo.save(goal(autoAmount: 200, period: 'monthly', lastRun: lastRun));

    await RunGoalAutoSavesUseCase(repo).call();

    final saved = await repo.getById('g1');
    expect(saved!.savedAmount, 200);
    final contribs = await repo.getContributions('g1');
    expect(contribs, hasLength(1));
    // last-run advanced so a second run adds nothing.
    await RunGoalAutoSavesUseCase(repo).call();
    final saved2 = await repo.getById('g1');
    expect(saved2!.savedAmount, 200);
  });

  test('catches up multiple due weekly periods', () async {
    final lastRun = DateTime.now().subtract(const Duration(days: 22));
    await repo.save(goal(autoAmount: 50, period: 'weekly', lastRun: lastRun));

    await RunGoalAutoSavesUseCase(repo).call();

    final saved = await repo.getById('g1');
    // 22 days ≈ 3 weekly periods.
    expect(saved!.savedAmount, 150);
  });

  test('does nothing when auto-save is off or goal not active', () async {
    await repo.save(goal()); // no auto-save
    await repo.save(goal(
        autoAmount: 100,
        period: 'monthly',
        lastRun: DateTime.now().subtract(const Duration(days: 60)),
        status: 'paused'));

    await RunGoalAutoSavesUseCase(repo).call();

    final saved = await repo.getById('g1');
    expect(saved!.savedAmount, 0);
  });
}
