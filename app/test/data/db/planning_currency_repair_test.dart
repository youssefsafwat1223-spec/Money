import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/planning_currency_repair.dart';
import 'package:money_companion/domain/finance/currency_scale.dart';

// MALI-026 (Phase-8 B8-2.6) — the pre-v30 planning-currency repair foundation.

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

/// In-memory [RepairKeyValueStore] (no platform channels) — the production wiring
/// is [SecureRepairKeyValueStore] over flutter_secure_storage.
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
  Future<void> addGoal(String id) => db.customStatement(
        "INSERT INTO goals(id, name, target_amount, saved_amount, vault_skin, "
        "status, created_at) VALUES ('$id', 'G', 1000.0, 250.0, 'default', "
        "'active', '2026-01-01T00:00:00Z');",
      );

  PlanningCurrencyRepairService service({
    String installId = 'install-A',
    String? userId,
  }) =>
      PlanningCurrencyRepairService(
          db: db, store: store, installId: installId, userId: userId);

  setUp(() async {
    store = _MemoryKv();
    db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
    catId = (await db.customSelect('SELECT id FROM categories LIMIT 1;')
            .getSingle())
        .read<String>('id');
  });
  tearDown(() => db.close());

  test('manifest round-trips (global + perRow)', () {
    for (final m in [
      const PlanningCurrencyRepairManifest(
        manifestVersion: 1,
        generatedAtIso: '2026-01-01T00:00:00Z',
        installId: 'i',
        userId: 'u',
        rowSetFingerprint: 'fp',
        mode: PlanningRepairMode.global,
        globalCurrency: 'EGP',
        perRowCurrency: {},
      ),
      const PlanningCurrencyRepairManifest(
        manifestVersion: 1,
        generatedAtIso: '2026-01-01T00:00:00Z',
        installId: 'i',
        userId: null,
        rowSetFingerprint: 'fp',
        mode: PlanningRepairMode.perRow,
        globalCurrency: null,
        perRowCurrency: {'b1': 'EGP', 'g1': 'KWD'},
      ),
    ]) {
      final decoded = PlanningCurrencyRepairManifest.tryDecode(m.encode())!;
      expect(decoded.mode, m.mode);
      expect(decoded.globalCurrency, m.globalCurrency);
      expect(decoded.perRowCurrency, m.perRowCurrency);
      expect(decoded.installId, m.installId);
      expect(decoded.userId, m.userId);
    }
  });

  test('Case A — no budgets/goals → notRequired', () async {
    expect(await service().evaluate(), PlanningRepairStatus.notRequired);
  });

  test('Case B — existing rows, no decision → needsConfirmation', () async {
    await addBudget('b1');
    await addGoal('g1');
    expect(await service().evaluate(), PlanningRepairStatus.needsConfirmation);
  });

  test('global confirmation → satisfied; migration currency is the confirmed one',
      () async {
    await addBudget('b1');
    await addGoal('g1');
    final s = service();
    await s.confirmGlobal('egp'); // normalizes to EGP
    expect(await s.evaluate(), PlanningRepairStatus.satisfied);
    expect(await s.migrationCurrencyForBudget('b1'), 'EGP');
    expect(await s.migrationCurrencyForGoal('g1'), 'EGP');
    // contributions inherit the parent goal's currency (no own authority).
    expect(await s.migrationCurrencyForContribution('g1'), 'EGP');
  });

  test('per-row confirmation must cover every id; then satisfied', () async {
    await addBudget('b1');
    await addGoal('g1');
    final s = service();
    await expectLater(
        s.confirmPerRow({'b1': 'EGP'}), throwsA(isA<ArgumentError>()));
    await s.confirmPerRow({'b1': 'EGP', 'g1': 'KWD'});
    expect(await s.evaluate(), PlanningRepairStatus.satisfied);
    expect(await s.migrationCurrencyForBudget('b1'), 'EGP');
    expect(await s.migrationCurrencyForGoal('g1'), 'KWD');
  });

  test('STALE — a row added after confirmation invalidates the decision',
      () async {
    await addBudget('b1');
    final s = service();
    await s.confirmGlobal('EGP');
    expect(await s.evaluate(), PlanningRepairStatus.satisfied);
    await addGoal('g-new'); // row-id set changes → fingerprint mismatch
    expect(await s.evaluate(), PlanningRepairStatus.stale);
    // migration consume API must block, not silently assume.
    await expectLater(
        s.migrationCurrencyForBudget('b1'), throwsA(isA<StateError>()));
  });

  test('a decision from another install does not apply here', () async {
    await addBudget('b1');
    await service(installId: 'install-A').confirmGlobal('EGP');
    // a service for a different install sees no valid manifest.
    expect(await service(installId: 'install-B').evaluate(),
        PlanningRepairStatus.needsConfirmation);
  });

  test('a decision bound to a user does not apply after that user changes',
      () async {
    await addBudget('b1');
    await service(userId: 'u1').confirmGlobal('EGP');
    expect(await service(userId: 'u2').evaluate(),
        PlanningRepairStatus.needsConfirmation);
    expect(await service(userId: 'u1').evaluate(),
        PlanningRepairStatus.satisfied);
  });

  test('unsupported currency is rejected at confirmation', () async {
    await addBudget('b1');
    await expectLater(service().confirmGlobal('ZZZ'),
        throwsA(isA<UnsupportedCurrencyException>()));
  });

  test('migration consume API blocks when unconfirmed (no base-currency stamp)',
      () async {
    await addBudget('b1');
    await expectLater(service().migrationCurrencyForBudget('b1'),
        throwsA(isA<StateError>()));
  });
}
