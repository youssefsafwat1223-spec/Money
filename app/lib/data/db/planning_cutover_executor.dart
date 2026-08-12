import '../../domain/finance/currency_scale.dart';
import '../../domain/finance/decimal_minor.dart';
import 'app_database.dart';
import 'planning_currency_repair.dart';
import 'planning_cutover.dart';

/// MALI-026 (Phase-8 B8-3 §13) — the P2 planning-currency cutover executor.
///
/// Converts historical planning money (budgets/goals/goal_contributions) from
/// legacy REAL to canonical `row.currency` + `_minor`, in ONE SQLite transaction,
/// gated on a SATISFIED LIVE_DATASET repair manifest. The durable marker flips to
/// canonical in the SAME transaction, so any failure rolls back BOTH the money
/// writes AND the marker — the dataset stays P1 (unresolved) all-or-nothing.

class PlanningCutoverRefused implements Exception {
  const PlanningCutoverRefused(this.message);
  final String message;
  @override
  String toString() => 'PlanningCutoverRefused: $message';
}

class PlanningCutoverExecutor {
  const PlanningCutoverExecutor(this._db, this._repair);

  final AppDatabase _db;
  final PlanningCurrencyRepairService _repair;

  /// Runs the cutover. Returns the resulting [PlanningCutoverState] (canonical on
  /// success) so the coordinator can refresh without a restart. Throws
  /// [PlanningCutoverRefused] when repair is not satisfied (nothing is mutated).
  Future<PlanningCutoverState> execute() async {
    // §13.1/2 — validate BEFORE mutating. Stale/needsConfirmation refuse (§4).
    final status = await _repair.evaluate();
    if (!mayExecutePlanningCutover(status)) {
      throw PlanningCutoverRefused('repair status is $status (not satisfied)');
    }
    if (status == PlanningRepairStatus.notRequired) {
      // No planning rows — trivially canonical, idempotent.
      await _db
          .customStatement('UPDATE user_settings SET planning_cutover_state = 1;');
      return PlanningCutoverState.canonical;
    }

    // §14 — load the confirmed decision ONCE (no per-row / per-contribution N+1).
    final manifest = await _repair.currentValidManifest();
    if (manifest == null) {
      throw const PlanningCutoverRefused('no valid repair manifest');
    }
    String currencyFor(String id) {
      final c = manifest.currencyForId(id);
      if (c == null || !isSupportedCurrency(c)) {
        throw PlanningCutoverRefused('no confirmed currency for "$id"');
      }
      return c;
    }

    await _db.transaction(() async {
      // Budgets: currency + amount/last_notified -> minor.
      final budgets = await _db
          .customSelect(
              'SELECT id, amount, last_notified_spent_amount FROM budgets;')
          .get();
      for (final b in budgets) {
        final id = b.read<String>('id');
        final scale = currencyScale(currencyFor(id));
        await _db.customStatement(
          'UPDATE budgets SET currency = ?, amount_minor = ?, '
          'last_notified_spent_amount_minor = ? WHERE id = ?;',
          [
            currencyFor(id),
            legacyRealToMinor(b.read<double>('amount'), scale),
            legacyRealToMinor(
                b.read<double>('last_notified_spent_amount'), scale),
            id,
          ],
        );
      }

      // Goals: currency + target/saved/last_notified/auto_save -> minor.
      final goals = await _db
          .customSelect('SELECT id, target_amount, saved_amount, '
              'last_notified_saved_amount, auto_save_amount FROM goals;')
          .get();
      for (final g in goals) {
        final id = g.read<String>('id');
        final scale = currencyScale(currencyFor(id));
        final autoSave = g.readNullable<double>('auto_save_amount');
        await _db.customStatement(
          'UPDATE goals SET currency = ?, target_amount_minor = ?, '
          'saved_amount_minor = ?, last_notified_saved_amount_minor = ?, '
          'auto_save_amount_minor = ? WHERE id = ?;',
          [
            currencyFor(id),
            legacyRealToMinor(g.read<double>('target_amount'), scale),
            legacyRealToMinor(g.read<double>('saved_amount'), scale),
            legacyRealToMinor(g.read<double>('last_notified_saved_amount'), scale),
            autoSave == null ? null : legacyRealToMinor(autoSave, scale),
            id,
          ],
        );
      }

      // Goal contributions: amount -> minor using the PARENT GOAL's currency
      // (§14 — resolved from the same in-memory manifest, no N+1).
      final contribs = await _db
          .customSelect('SELECT id, amount, goal_id FROM goal_contributions;')
          .get();
      for (final c in contribs) {
        final parentGoalId = c.read<String>('goal_id');
        final scale = currencyScale(currencyFor(parentGoalId));
        await _db.customStatement(
          'UPDATE goal_contributions SET amount_minor = ? WHERE id = ?;',
          [
            legacyRealToMinor(c.read<double>('amount'), scale),
            c.read<String>('id'),
          ],
        );
      }

      // §13.8 exact postflight (throws → rolls back everything, marker included).
      await _verifyPlanningCanonical();

      // §13.9 — marker flips in the SAME transaction.
      await _db
          .customStatement('UPDATE user_settings SET planning_cutover_state = 1;');
    });

    return PlanningCutoverState.canonical;
  }

  /// Exact postflight over the just-converted planning money (no epsilon): every
  /// budget/goal carries a currency, every non-null legacy REAL has a `_minor`
  /// that round-trips exactly, and contributions have a minor.
  Future<void> _verifyPlanningCanonical() async {
    Future<void> checkSameCurrency(String table, List<String> fields) async {
      final rows = await _db.customSelect('SELECT * FROM $table;').get();
      for (final row in rows) {
        final cur = row.readNullable<String>('currency');
        if (cur == null) {
          throw PlanningCutoverInvariantException('$table row missing currency');
        }
        final scale = currencyScale(cur);
        for (final f in fields) {
          final real = row.readNullable<double>(f);
          final minor = row.readNullable<int>('${f}_minor');
          if (real == null) {
            if (minor != null) {
              throw PlanningCutoverInvariantException(
                  '$table.$f: minor non-null for NULL REAL');
            }
            continue;
          }
          if (minor == null || minor != legacyRealToMinor(real, scale)) {
            throw PlanningCutoverInvariantException(
                '$table.$f: minor mismatch (stored=$minor)');
          }
        }
      }
    }

    await checkSameCurrency('budgets', ['amount', 'last_notified_spent_amount']);
    await checkSameCurrency('goals', [
      'target_amount',
      'saved_amount',
      'last_notified_saved_amount',
      'auto_save_amount',
    ]);
    // Contributions inherit the parent goal's currency; verify the stored
    // amount_minor round-trips exactly against that currency.
    final contribs = await _db
        .customSelect('SELECT gc.amount AS amount, gc.amount_minor AS minor, '
            'g.currency AS cur FROM goal_contributions gc '
            'JOIN goals g ON g.id = gc.goal_id;')
        .get();
    for (final c in contribs) {
      final cur = c.readNullable<String>('cur');
      if (cur == null) {
        throw const PlanningCutoverInvariantException(
            'goal_contributions: parent goal missing currency');
      }
      final stored = c.readNullable<int>('minor');
      final expected =
          legacyRealToMinor(c.read<double>('amount'), currencyScale(cur));
      if (stored == null || stored != expected) {
        throw const PlanningCutoverInvariantException(
            'goal_contributions: amount_minor mismatch');
      }
    }
  }
}
