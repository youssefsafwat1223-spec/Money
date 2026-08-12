import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backup/planning_restore_preflight.dart';
import 'package:money_companion/core/backup/restore_backup_usecase.dart';
import 'package:money_companion/core/backup/restore_result.dart'
    show RestorePlanningRepairRequiredException;
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/planning_canonical_invariants.dart';
import 'package:money_companion/data/db/planning_cutover.dart';
import 'package:money_companion/data/db/planning_currency_repair.dart'
    show PlanningRepairMode;

// MALI-026 (B8-3 Step 4 §26/§7/§8) — RESTORE must never introduce a
// non-canonical v30 planning row, bypass the cutover, or leave a false canonical
// marker; a planning-invariant failure rolls the WHOLE restore back atomically.
// The v3 backup envelope is unchanged, so a planning payload carries REAL only
// (no currency / no `_minor`) — exactly like a legacy backup. Hence:
//   (1) P1 restore: legacy live DB + currency-less planning → lands at P1
//       (marker reconciled to unresolved from the ACTUAL data, never the backup);
//   (3) P3 restore: canonical live DB + matching payload decision → restored
//       planning is canonical (row.currency + exact `_minor` from the DECISION,
//       never base) and the marker is canonical;
//   (8) a fault after the planning canonicalization rolls everything back —
//       original data intact, marker unchanged, no partial planning restore.

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

const _canonical =
    FixedPlanningCutoverCoordinator(PlanningCutoverState.canonical);
const _legacy = FixedPlanningCutoverCoordinator(PlanningCutoverState.legacy);

// A v3 snapshot whose planning rows carry REAL only (no currency / no `_minor`),
// exactly as the unchanged envelope exports them.
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

  Future<int> marker(AppDatabase db) async => (await db
          .customSelect(
              'SELECT planning_cutover_state AS m FROM user_settings LIMIT 1;')
          .getSingle())
      .read<int>('m');

  // Scenario 1 — P1 restore. A legacy live DB restoring a currency-less planning
  // payload lands at P1: the marker is reconciled to UNRESOLVED from the actual
  // (still legacy) restored rows — never a canonical marker from the backup.
  test('(1) legacy restore of currency-less planning → lands at P1', () async {
    final db = await open();
    addTearDown(db.close);

    await RestoreBackupUseCase(db, coordinator: _legacy)
        .call(_planningSnapshot());

    // Rows restored, but still legacy: no currency, no `_minor`.
    expect(await count(db, "budgets WHERE id='b_snap'"), 1);
    expect(await count(db, "budgets WHERE id='b_snap' AND currency IS NULL"), 1);
    expect(
        await count(db, "budgets WHERE id='b_snap' AND amount_minor IS NULL"), 1);

    // Marker reconciled to unresolved (0), and an independent recompute agrees.
    expect(await marker(db), 0);
    final violations = await planningCanonicalViolations(db);
    expect(violations, isNotEmpty);
    final state = await computePlanningCutoverState(
      () async => 30,
      () async => await marker(db),
      () async => violations.length,
    );
    expect(state, PlanningCutoverState.unresolved);
  });

  // Scenario 3 — P3 restore. Canonical live DB + a matching RESTORE_PAYLOAD
  // decision → the restored planning is CANONICAL: each row gets its confirmed
  // currency (from the decision, not the base) and an exact `_minor`, and the
  // marker ends canonical.
  test('(3) canonical restore + decision → exact canonical planning + marker=1',
      () async {
    final db = await open();
    addTearDown(db.close);

    final tables = _planningSnapshot()['tables'] as Map<String, dynamic>;
    final fingerprint =
        restorePayloadFingerprint(restoreSnapshotPlanningRows(tables));
    final decision = RestorePayloadRepairDecision(
      payloadFingerprint: fingerprint,
      mode: PlanningRepairMode.global,
      globalCurrency: 'EGP', // 2-decimal
      perRowCurrency: const {},
    );

    await RestoreBackupUseCase(db, coordinator: _canonical).call(
      _planningSnapshot(),
      planningRepairDecision: decision,
    );

    // Budget canonical: currency + exact minor (250.00 EGP → 25000).
    final b = await db
        .customSelect(
            "SELECT currency, amount_minor AS m FROM budgets WHERE id='b_snap';")
        .getSingle();
    expect(b.read<String>('currency'), 'EGP');
    expect(b.read<int>('m'), 25000);

    // Goal canonical: currency + exact minors (1000.00 → 100000, 100.00 → 10000).
    final g = await db
        .customSelect("SELECT currency, target_amount_minor AS t, "
            "saved_amount_minor AS s FROM goals WHERE id='g_snap';")
        .getSingle();
    expect(g.read<String>('currency'), 'EGP');
    expect(g.read<int>('t'), 100000);
    expect(g.read<int>('s'), 10000);

    // No canonical violations remain, and the marker is canonical.
    expect(await planningCanonicalViolations(db), isEmpty);
    expect(await marker(db), 1);
  });

  // Scenario 8 — atomic rollback. A failure AFTER the planning canonicalization +
  // marker write rolls the WHOLE restore back: the original canonical data
  // survives, the marker is unchanged, and no snapshot row (partial planning
  // restore) is left behind.
  test('(8) fault after planning canonicalization → whole restore rolls back',
      () async {
    final db = await open();
    addTearDown(db.close);

    // Seed an existing CANONICAL budget + canonical marker in the live DB.
    await db.customStatement(
      "INSERT INTO budgets(id, category_id, currency, amount, amount_minor, "
      "period, start_date, is_active) VALUES ('live_b', "
      "(SELECT id FROM categories LIMIT 1), 'SAR', 42.00, 4200, 'monthly', "
      "'2026-01-01T00:00:00Z', 1);",
    );
    await db.customStatement(
        'UPDATE user_settings SET planning_cutover_state = 1;');
    final liveBudgets = await count(db, 'budgets');

    final tables = _planningSnapshot()['tables'] as Map<String, dynamic>;
    final decision = RestorePayloadRepairDecision(
      payloadFingerprint:
          restorePayloadFingerprint(restoreSnapshotPlanningRows(tables)),
      mode: PlanningRepairMode.global,
      globalCurrency: 'EGP',
      perRowCurrency: const {},
    );

    await expectLater(
      RestoreBackupUseCase(db, coordinator: _canonical).call(
        _planningSnapshot(),
        planningRepairDecision: decision,
        // Fires after the planning canonicalization + marker reconciliation, so
        // the rollback must undo BOTH along with the destructive delete/insert.
        onFaultPoint: (p) {
          if (p == 'beforeVerification') {
            throw StateError('injected post-canonicalization failure');
          }
        },
      ),
      throwsA(isA<Object>()),
    );

    // Everything rolled back: original canonical budget intact, marker unchanged,
    // no snapshot rows applied.
    expect(await count(db, 'budgets'), liveBudgets);
    expect(await count(db, "budgets WHERE id='live_b' AND amount_minor=4200"), 1);
    expect(await count(db, "budgets WHERE id='b_snap'"), 0);
    expect(await marker(db), 1);
  });

  // Guard: a currency-less planning payload restored into a canonical DB WITHOUT
  // a decision still aborts before any destructive mutation (envelope-unchanged
  // consequence — see the restore preflight integration test for the full set).
  test('canonical restore without a decision aborts (no non-canonical rows)',
      () async {
    final db = await open();
    addTearDown(db.close);
    await expectLater(
      RestoreBackupUseCase(db, coordinator: _canonical).call(_planningSnapshot()),
      throwsA(isA<RestorePlanningRepairRequiredException>()),
    );
    expect(await count(db, "budgets WHERE id='b_snap'"), 0);
  });
}
