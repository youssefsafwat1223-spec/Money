import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backup/planning_restore_preflight.dart';
import 'package:money_companion/core/backup/restore_backup_usecase.dart';
import 'package:money_companion/core/backup/restore_result.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/planning_cutover.dart';
import 'package:money_companion/data/db/planning_currency_repair.dart'
    show PlanningRepairMode;

// MALI-026 (Phase-8 B8-2.10 §5/§6/§7) — the restore preflight is wired into the
// REAL destructive restore use case. These tests drive RestoreBackupUseCase.call
// (no test double) against an in-memory DB and prove:
//   §5  canonical live DB + currency-less legacy planning payload -> throws
//       BEFORE any destructive mutation, original DB unchanged;
//   §5  legacy live DB (schema v29 today) -> restore proceeds unchanged;
//   §7  a fresh RESTORE_PAYLOAD-scoped decision lets the restore continue;
//   §6  a decision from a DIFFERENT scope (a live-dataset fingerprint) does NOT
//       satisfy the payload — repair still required (cross-scope rejection).

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

const _canonical =
    FixedPlanningCutoverCoordinator(PlanningCutoverState.canonical);
const _legacy = FixedPlanningCutoverCoordinator(PlanningCutoverState.legacy);

Map<String, dynamic> _planningSnapshot() => <String, dynamic>{
      'schemaVersion': 3,
      'tables': <String, dynamic>{
        'categories': <Map<String, dynamic>>[
          {
            'id': 'c1',
            'key': 'k1',
            'name_ar': 'x',
            'icon': 'i',
            'color': '#ffffff',
            'is_income': 0,
            'sort_order': 0,
          }
        ],
        'accounts': <Map<String, dynamic>>[
          {
            'id': 'acc1',
            'name': 'A',
            'currency': 'SAR',
            'type': 'bank',
            'created_at': '2026-01-01',
            'updated_at': '2026-01-01',
          }
        ],
        'user_settings': <Map<String, dynamic>>[
          {
            'id': 'settings',
            'country': 'SA',
            'currency': 'SAR',
            'language': 'ar',
            'theme': 'dark',
            'input_method': 'manual',
            'notifications_json': '{}',
            'db_encryption_key_ref': 'ref',
          }
        ],
        'budgets': <Map<String, dynamic>>[
          {
            'id': 'b_snap',
            'category_id': 'c1',
            'amount': 250.0,
            'period': 'monthly',
            'start_date': '2026-01-01T00:00:00Z',
            'is_active': 1,
          }
        ],
        'goals': <Map<String, dynamic>>[
          {
            'id': 'g_snap',
            'name': 'Trip',
            'target_amount': 1000.0,
            'saved_amount': 100.0,
            'vault_skin': 'default',
            'status': 'active',
            'created_at': '2026-02-01T00:00:00Z',
          }
        ],
      },
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppDatabase> open() => AppDatabase.open(
        executor: NativeDatabase.memory(),
        keyStore: _MemoryKeyStore(),
      );

  Future<int> count(AppDatabase db, String sql) async =>
      (await db.customSelect('SELECT COUNT(*) AS n FROM $sql;').getSingle())
          .read<int>('n');

  test('§5 canonical + currency-less planning payload → throws, DB unchanged',
      () async {
    final db = await open();
    addTearDown(db.close);
    // Seed a live budget that a destructive restore would delete.
    await db.customStatement(
      "INSERT INTO budgets(id, category_id, amount, period, start_date, "
      "is_active) VALUES ('live_b', "
      "(SELECT id FROM categories LIMIT 1), 99.0, 'monthly', "
      "'2026-01-01T00:00:00Z', 1);",
    );
    final liveBudgets = await count(db, 'budgets');

    await expectLater(
      RestoreBackupUseCase(db, coordinator: _canonical).call(_planningSnapshot()),
      throwsA(isA<RestorePlanningRepairRequiredException>()),
    );

    // Original DB byte/logical state intact: the live budget survives and the
    // snapshot's rows were never inserted (no DELETE, no INSERT ran).
    expect(await count(db, 'budgets'), liveBudgets);
    expect(await count(db, "budgets WHERE id='live_b'"), 1);
    expect(await count(db, "budgets WHERE id='b_snap'"), 0);
  });

  test('§5 legacy (v29) → restore proceeds unchanged', () async {
    final db = await open();
    addTearDown(db.close);
    await RestoreBackupUseCase(db, coordinator: _legacy).call(_planningSnapshot());
    expect(await count(db, "budgets WHERE id='b_snap'"), 1);
    expect(await count(db, "goals WHERE id='g_snap'"), 1);
  });

  test('§7 canonical + matching payload decision → restore continues', () async {
    final db = await open();
    addTearDown(db.close);
    final tables =
        _planningSnapshot()['tables'] as Map<String, dynamic>;
    final fingerprint =
        restorePayloadFingerprint(restoreSnapshotPlanningRows(tables));
    final decision = RestorePayloadRepairDecision(
      payloadFingerprint: fingerprint,
      mode: PlanningRepairMode.global,
      globalCurrency: 'EGP',
      perRowCurrency: const {},
    );

    await RestoreBackupUseCase(db, coordinator: _canonical).call(
      _planningSnapshot(),
      planningRepairDecision: decision,
    );
    expect(await count(db, "budgets WHERE id='b_snap'"), 1);
    expect(await count(db, "goals WHERE id='g_snap'"), 1);
  });

  test('§6 a live-dataset-scoped decision does NOT satisfy the restore payload',
      () async {
    final db = await open();
    addTearDown(db.close);
    // A decision bound to a DIFFERENT fingerprint (as a LIVE_DATASET decision
    // would be) must be rejected — the payload still needs its own repair.
    const wrongScope = RestorePayloadRepairDecision(
      payloadFingerprint: 'LIVE_DATASET_fingerprint_not_the_payload',
      mode: PlanningRepairMode.global,
      globalCurrency: 'EGP',
      perRowCurrency: {},
    );

    await expectLater(
      RestoreBackupUseCase(db, coordinator: _canonical).call(
        _planningSnapshot(),
        planningRepairDecision: wrongScope,
      ),
      throwsA(isA<RestorePlanningRepairRequiredException>()),
    );
    expect(await count(db, "budgets WHERE id='b_snap'"), 0);
  });

  test('§7 continuation mapping: per-row currency, contribution inherits goal',
      () {
    const decision = RestorePayloadRepairDecision(
      payloadFingerprint: 'fp',
      mode: PlanningRepairMode.perRow,
      globalCurrency: null,
      perRowCurrency: {'b_snap': 'EGP', 'g_snap': 'KWD'},
    );
    // budget uses its own confirmed currency; goal uses its own; a contribution
    // inherits its parent goal's currency — never a base-currency fallback.
    expect(restoreLegacyAmountToMinor(250.0, decision.currencyForId('b_snap')),
        25000); // EGP, 2-dec
    expect(restoreLegacyAmountToMinor(1.0, decision.currencyForId('g_snap')),
        1000); // KWD, 3-dec
    expect(
        restoreLegacyAmountToMinor(1.0, decision.contributionCurrency('g_snap')),
        1000); // inherits KWD
  });
}
