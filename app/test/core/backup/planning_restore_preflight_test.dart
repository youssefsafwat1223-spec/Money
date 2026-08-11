import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backup/planning_restore_preflight.dart';
import 'package:money_companion/data/db/planning_currency_repair.dart'
    show PlanningRepairMode;
import 'package:money_companion/domain/finance/currency_scale.dart';

// MALI-026 (Phase-8 B8-2.9 §6/§7/§8) — planning restore-preflight foundation.
// Pure logic (no crypto/backup setUp) — safe to run standalone.

void main() {
  const legacyBudget = RestorePlanningRow(id: 'b1', isGoal: false, legacyAmount: 100.0);
  const legacyGoal = RestorePlanningRow(
      id: 'g1', isGoal: true, legacyAmount: 1000.0, createdAt: '2026-01-01T00:00:00Z');

  test('empty planning payload → ready', () {
    expect(
        inspectPlanningRestorePayload(planningRows: const [], rowsLackCurrency: true),
        isA<RestoreReady>());
  });

  test('legacy payload lacking currency → repair required (STOP before restore)',
      () {
    final r = inspectPlanningRestorePayload(
        planningRows: const [legacyBudget, legacyGoal], rowsLackCurrency: true);
    expect(r, isA<RestorePlanningCurrencyRepairRequired>());
    final req = r as RestorePlanningCurrencyRepairRequired;
    expect(req.rows.length, 2);
    expect(req.payloadFingerprint, isNotEmpty);
    // §7/§9 — scoped to the payload, NEVER the live-dataset manifest.
    expect(req.scope, startsWith('RESTORE_PAYLOAD:'));
    expect(req.scope.contains('LIVE_DATASET'), isFalse);
  });

  test('payload whose rows already carry a currency → ready', () {
    expect(
        inspectPlanningRestorePayload(
            planningRows: const [legacyBudget], rowsLackCurrency: false),
        isA<RestoreReady>());
  });

  test('§5-E no destructive restore before a repair decision exists', () {
    // The contract: a caller may only run the destructive DELETE/INSERT when the
    // preflight is RestoreReady. A repair-required payload must halt.
    bool mayApplyDestructiveRestore(RestorePreflightResult r) => r is RestoreReady;
    final blocked = inspectPlanningRestorePayload(
        planningRows: const [legacyBudget], rowsLackCurrency: true);
    expect(mayApplyDestructiveRestore(blocked), isFalse);
    final ready = inspectPlanningRestorePayload(
        planningRows: const [legacyBudget], rowsLackCurrency: false);
    expect(mayApplyDestructiveRestore(ready), isTrue);
  });

  test('payload fingerprint tracks the payload identity set (id / id+created_at)',
      () {
    final fp1 = restorePayloadFingerprint(const [legacyBudget, legacyGoal]);
    // a different goal created_at (a different restored object) → different fp.
    const goal2 = RestorePlanningRow(
        id: 'g1', isGoal: true, legacyAmount: 1000.0, createdAt: '2020-06-15T00:00:00Z');
    final fp2 = restorePayloadFingerprint(const [legacyBudget, goal2]);
    expect(fp1, isNot(fp2));
  });

  test('payload-scoped decision: global / per-row / contribution inherits goal',
      () {
    const global = RestorePayloadRepairDecision(
        payloadFingerprint: 'fp',
        mode: PlanningRepairMode.global,
        globalCurrency: 'EGP',
        perRowCurrency: {});
    expect(global.currencyForId('b1'), 'EGP');
    expect(global.contributionCurrency('g1'), 'EGP');

    const perRow = RestorePayloadRepairDecision(
        payloadFingerprint: 'fp',
        mode: PlanningRepairMode.perRow,
        globalCurrency: null,
        perRowCurrency: {'b1': 'EGP', 'g1': 'KWD'});
    expect(perRow.currencyForId('b1'), 'EGP');
    expect(perRow.currencyForId('g1'), 'KWD');
    expect(perRow.contributionCurrency('g1'), 'KWD'); // inherits parent goal
    expect(() => perRow.currencyForId('missing'), throwsA(isA<StateError>()));
  });

  test('§8 canonical conversion uses the confirmed currency (no base fallback)',
      () {
    expect(restoreLegacyAmountToMinor(100.0, 'EGP'), 10000); // 2-dec
    expect(restoreLegacyAmountToMinor(1.234, 'KWD'), 1234); // 3-dec
    expect(restoreLegacyAmountToMinor(1234.0, 'JPY'), 1234); // 0-dec
    expect(() => restoreLegacyAmountToMinor(1.0, 'ZZZ'),
        throwsA(isA<UnsupportedCurrencyException>()));
  });
}
