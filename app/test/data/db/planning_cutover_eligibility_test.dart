import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/planning_currency_repair.dart';

// MALI-026 (Phase-8 B8-2.10 §4) — a satisfied repair that is then invalidated by
// a dataset replacement goes stale, and the cutover-eligibility contract refuses
// execution. Stale is NEVER treated as satisfied.

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

  late AppDatabase db;
  late _MemoryKv store;
  late String catId;

  Future<void> addBudget(String id) => db.customStatement(
        "INSERT INTO budgets(id, category_id, amount, period, start_date, "
        "is_active) VALUES ('$id', '$catId', 100.0, 'monthly', "
        "'2026-01-01T00:00:00Z', 1);",
      );

  PlanningCurrencyRepairService service() => PlanningCurrencyRepairService(
      db: db, store: store, installId: 'install-A', userId: 'user-A');

  setUp(() async {
    store = _MemoryKv();
    db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
    catId = (await db.customSelect('SELECT id FROM categories LIMIT 1;')
            .getSingle())
        .read<String>('id');
  });
  tearDown(() => db.close());

  test('satisfied repair is cutover-eligible', () async {
    await addBudget('b1');
    final s = service();
    await s.confirmGlobal('EGP');
    expect(await s.evaluate(), PlanningRepairStatus.satisfied);
    expect(mayExecutePlanningCutover(await s.evaluate()), isTrue);
  });

  test('a dataset replacement after confirmation goes stale → cutover refused',
      () async {
    await addBudget('b1');
    final s = service();
    await s.confirmGlobal('EGP');
    expect(await s.evaluate(), PlanningRepairStatus.satisfied);

    // The confirmed dataset is replaced/extended — the fingerprint no longer
    // matches the confirmed decision.
    await addBudget('b2');
    final status = await s.evaluate();
    expect(status, PlanningRepairStatus.stale);
    expect(mayExecutePlanningCutover(status), isFalse,
        reason: 'stale must never authorize the cutover');
  });

  test('needsConfirmation is not cutover-eligible', () async {
    await addBudget('b1');
    final status = await service().evaluate();
    expect(status, PlanningRepairStatus.needsConfirmation);
    expect(mayExecutePlanningCutover(status), isFalse);
  });

  test('notRequired (no planning rows) is eligible — no ambiguity to repair',
      () async {
    final status = await service().evaluate();
    expect(status, PlanningRepairStatus.notRequired);
    expect(mayExecutePlanningCutover(status), isTrue);
  });
}
