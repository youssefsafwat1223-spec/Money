import '../../domain/finance/currency_scale.dart';
import '../../domain/finance/decimal_minor.dart';
import 'app_database.dart';
import 'planning_canonical_invariants.dart';
import 'planning_currency_repair.dart';
import 'planning_cutover.dart';

/// MALI-026 (Phase-8 B8-3 §13, corrections 1/2/3/5) — the P2 planning-currency
/// cutover executor.
///
/// Converts historical planning money (budgets/goals/goal_contributions) from
/// legacy REAL to canonical `row.currency` + `_minor` in ONE SQLite transaction,
/// gated on a SATISFIED LIVE_DATASET repair manifest. The manifest is revalidated
/// against the TRANSACTIONAL row-set snapshot (not a pre-transaction read), so the
/// set validated == the set converted (no TOCTOU; the guard is not relied upon).
/// The durable marker flips to canonical in the SAME transaction — any failure
/// rolls back BOTH money AND marker, leaving P1 all-or-nothing. On success the
/// state is INDEPENDENTLY recomputed from the committed DB (never asserted).

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

  Future<int> _readUserVersion() async => (await _db
          .customSelect('PRAGMA user_version;')
          .getSingle())
      .read<int>('user_version');
  Future<int> _readMarker() async => (await _db
          .customSelect('SELECT planning_cutover_state AS s FROM user_settings;')
          .getSingle())
      .read<int>('s');
  Future<int> _readViolations() async =>
      (await planningCanonicalViolations(_db)).length;

  /// Runs the cutover. Throws [PlanningCutoverRefused] when repair is not
  /// satisfied / went stale (nothing mutated). On success, returns the state
  /// RECOMPUTED from the committed DB (correction 2 — never a caller-asserted
  /// canonical).
  Future<PlanningCutoverState> execute() async {
    final status = await _repair.evaluate();
    if (!mayExecutePlanningCutover(status)) {
      throw PlanningCutoverRefused('repair status is $status (not satisfied)');
    }
    if (status == PlanningRepairStatus.notRequired) {
      await _db
          .customStatement('UPDATE user_settings SET planning_cutover_state = 1;');
      return computePlanningCutoverState(
          _readUserVersion, _readMarker, _readViolations);
    }

    // Snapshot the confirmed manifest from secure storage + validate its
    // install/user binding (§correction 1, BEFORE the transaction).
    final manifest = await _repair.currentValidManifest();
    if (manifest == null) {
      throw const PlanningCutoverRefused('no valid repair manifest');
    }
    String currencyFor(String id) {
      final c = manifest.currencyForId(id);
      if (c == null || !isSupportedCurrency(c)) {
        throw PlanningCutoverRefused('no confirmed supported currency for "$id"');
      }
      return c;
    }

    await _db.transaction(() async {
      // §0 (correction 1) — revalidate the manifest against the CURRENT
      // TRANSACTIONAL snapshot: recompute the live fingerprint via the same
      // connection (so it reads inside this transaction) and require an exact
      // match. Set-validated == set-converted; no TOCTOU, no reliance on the
      // mutation guard.
      final txFingerprint = await _repair.computeFingerprint();
      if (txFingerprint != manifest.rowSetFingerprint) {
        throw const PlanningCutoverRefused(
            'stale: transactional fingerprint != confirmed manifest');
      }

      // Budgets: currency + amount/last_notified -> minor.
      for (final b in await _db
          .customSelect(
              'SELECT id, amount, last_notified_spent_amount FROM budgets;')
          .get()) {
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

      // Goals: currency + target/saved/last_notified/auto_save -> minor. Build the
      // parent-goal currency map ONCE for the contributions (§5 — no N+1, no
      // manifest.currencyForId(contribution.id)).
      final goalCurrency = <String, String>{};
      for (final g in await _db
          .customSelect('SELECT id, target_amount, saved_amount, '
              'last_notified_saved_amount, auto_save_amount FROM goals;')
          .get()) {
        final id = g.read<String>('id');
        final cur = currencyFor(id);
        goalCurrency[id] = cur;
        final scale = currencyScale(cur);
        final autoSave = g.readNullable<double>('auto_save_amount');
        await _db.customStatement(
          'UPDATE goals SET currency = ?, target_amount_minor = ?, '
          'saved_amount_minor = ?, last_notified_saved_amount_minor = ?, '
          'auto_save_amount_minor = ? WHERE id = ?;',
          [
            cur,
            legacyRealToMinor(g.read<double>('target_amount'), scale),
            legacyRealToMinor(g.read<double>('saved_amount'), scale),
            legacyRealToMinor(g.read<double>('last_notified_saved_amount'), scale),
            autoSave == null ? null : legacyRealToMinor(autoSave, scale),
            id,
          ],
        );
      }

      // Goal contributions: amount -> minor using the PARENT GOAL's currency from
      // the preloaded map. A contribution whose parent goal is absent from the map
      // is an orphan -> throw -> whole rollback. No base-currency fallback.
      for (final c in await _db
          .customSelect('SELECT id, amount, goal_id FROM goal_contributions;')
          .get()) {
        final parentGoalId = c.read<String>('goal_id');
        final cur = goalCurrency[parentGoalId];
        if (cur == null) {
          throw PlanningCutoverRefused(
              'goal_contributions.${c.read<String>('id')}: parent goal '
              '$parentGoalId not in the converted goal set');
        }
        await _db.customStatement(
          'UPDATE goal_contributions SET amount_minor = ? WHERE id = ?;',
          [
            legacyRealToMinor(c.read<double>('amount'), currencyScale(cur)),
            c.read<String>('id'),
          ],
        );
      }

      // §13.11 exact whole-contract postflight (throws → rolls back everything,
      // marker included).
      final violations = await planningCanonicalViolations(_db);
      if (violations.isNotEmpty) {
        throw PlanningCutoverInvariantException(violations.first);
      }

      // §13.12 — marker flips ONLY after every invariant passed, in the SAME txn.
      await _db
          .customStatement('UPDATE user_settings SET planning_cutover_state = 1;');
    });

    // Correction 2 — resolve the resulting state by INDEPENDENTLY re-reading the
    // committed DB (marker + violations), never by asserting canonical.
    return computePlanningCutoverState(
        _readUserVersion, _readMarker, _readViolations);
  }
}
