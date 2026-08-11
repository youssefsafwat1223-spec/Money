import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../data/db/planning_cutover.dart';
import '../../data/db/planning_currency_repair.dart' show PlanningRepairMode;
import '../../domain/finance/currency_scale.dart';
import '../../domain/finance/decimal_minor.dart';

/// MALI-026 (Phase-8 B8-2.9 §6/§7/§8) — the pre-restore planning-currency
/// ambiguity preflight foundation.
///
/// A legacy (v3) backup contains budgets/goals with money REAL but NO stored
/// currency. Once the live DB is canonical (P3), restoring such a payload must
/// NOT insert ambiguous rows: the restore flow decrypts + validates, inspects the
/// planning rows, and — if any lack a stable currency — returns
/// [RestorePlanningCurrencyRepairRequired] and STOPS before any destructive local
/// DELETE/INSERT. The repair decision is scoped to the RESTORE PAYLOAD's OWN
/// fingerprint (never the live-dataset manifest — §9), and the canonical
/// conversion uses ONLY the confirmed currency (never baseCurrencyProvider — §8).
///
/// This is the FOUNDATION (result states + payload fingerprint + payload-scoped
/// decision + canonical-conversion prototype + tests). Wiring into the live
/// restore transaction lands with v30; no schema/format change here.

/// One planning row extracted from a decrypted backup payload. Legacy payloads
/// carry no currency; goals carry an immutable `created_at`.
class RestorePlanningRow {
  const RestorePlanningRow({
    required this.id,
    required this.isGoal,
    required this.legacyAmount,
    this.createdAt,
    this.parentGoalId,
  });
  final String id;
  final bool isGoal; // false = budget
  final double legacyAmount;
  final String? createdAt; // goals only
  final String? parentGoalId; // contributions only (currency inherited)
}

sealed class RestorePreflightResult {
  const RestorePreflightResult();
}

/// No planning rows, or every planning row already carries a stable currency.
class RestoreReady extends RestorePreflightResult {
  const RestoreReady();
}

/// Planning rows lack a stable currency — a RESTORE_PAYLOAD-scoped repair decision
/// is required BEFORE any destructive restore.
class RestorePlanningCurrencyRepairRequired extends RestorePreflightResult {
  const RestorePlanningCurrencyRepairRequired(this.payloadFingerprint, this.rows);

  /// Scope key — DISTINCT from the live-dataset manifest; never cross-applied.
  String get scope => 'RESTORE_PAYLOAD:$payloadFingerprint';
  final String payloadFingerprint;
  final List<RestorePlanningRow> rows;
}

/// The payload could not be understood; do not restore.
class RestoreInvalid extends RestorePreflightResult {
  const RestoreInvalid(this.reason);
  final String reason;
}

/// Fingerprint of the restore payload's planning identity set (budgets by id;
/// goals by id+created_at) — the same identity policy as the live fingerprint,
/// but computed over the PAYLOAD and used only under the RESTORE_PAYLOAD scope.
String restorePayloadFingerprint(List<RestorePlanningRow> rows) {
  final budgets = rows.where((r) => !r.isGoal).toList()
    ..sort((a, b) => a.id.compareTo(b.id));
  final goals = rows.where((r) => r.isGoal).toList()
    ..sort((a, b) => a.id.compareTo(b.id));
  final parts = <String>[
    for (final b in budgets) 'b|${b.id}',
    for (final g in goals) 'g|${g.id}|${g.createdAt ?? ''}',
  ];
  return sha256.convert(utf8.encode(parts.join('\n'))).toString();
}

/// Inspect a decrypted backup's planning rows BEFORE any destructive restore.
/// [rowsLackCurrency] is true for a legacy payload (no stored planning currency).
RestorePreflightResult inspectPlanningRestorePayload({
  required List<RestorePlanningRow> planningRows,
  required bool rowsLackCurrency,
}) {
  if (planningRows.isEmpty) return const RestoreReady();
  if (!rowsLackCurrency) return const RestoreReady();
  return RestorePlanningCurrencyRepairRequired(
      restorePayloadFingerprint(planningRows), planningRows);
}

/// A RESTORE_PAYLOAD-scoped repair decision — same shape as the live manifest but
/// bound to the payload fingerprint and NEVER read from / written to the live
/// manifest's storage (no accidental cross-application).
class RestorePayloadRepairDecision {
  const RestorePayloadRepairDecision({
    required this.payloadFingerprint,
    required this.mode,
    required this.globalCurrency,
    required this.perRowCurrency,
  });

  final String payloadFingerprint;
  final PlanningRepairMode mode;
  final String? globalCurrency; // global mode
  final Map<String, String> perRowCurrency; // per-row mode (budget/goal id)

  /// The confirmed currency for a budget/goal id (contributions resolve via their
  /// parent goal id — see [contributionCurrency]).
  String currencyForId(String id) {
    final code = mode == PlanningRepairMode.global
        ? globalCurrency
        : perRowCurrency[id];
    if (code == null) {
      throw StateError('no confirmed restore currency for "$id"');
    }
    return code;
  }

  /// Contribution currency = its parent restored goal's confirmed currency.
  String contributionCurrency(String parentGoalId) =>
      currencyForId(parentGoalId);
}

/// §8 canonical conversion prototype: legacy REAL + the payload-confirmed currency
/// -> exact int64 minor. NO baseCurrencyProvider fallback. At real v30 the SAME
/// validated mapping writes `row.currency` + `*_minor` + the REAL shadow inside the
/// destructive restore transaction.
int restoreLegacyAmountToMinor(double legacyAmount, String confirmedCurrency) =>
    legacyRealToMinor(legacyAmount, currencyScale(confirmedCurrency));

/// Extract the planning identity rows from a restore snapshot's `tables` map.
/// Only budgets + goals participate (goal_contributions inherit their parent
/// goal's confirmed currency, so they are not fingerprinted here).
List<RestorePlanningRow> restoreSnapshotPlanningRows(
    Map<String, dynamic> tables) {
  final rows = <RestorePlanningRow>[];
  for (final b in (tables['budgets'] as List<dynamic>? ?? const [])
      .cast<Map<String, dynamic>>()) {
    rows.add(RestorePlanningRow(
      id: b['id'] as String,
      isGoal: false,
      legacyAmount: (b['amount'] as num?)?.toDouble() ?? 0,
    ));
  }
  for (final g in (tables['goals'] as List<dynamic>? ?? const [])
      .cast<Map<String, dynamic>>()) {
    rows.add(RestorePlanningRow(
      id: g['id'] as String,
      isGoal: true,
      legacyAmount: (g['target_amount'] as num?)?.toDouble() ?? 0,
      createdAt: g['created_at'] as String?,
    ));
  }
  return rows;
}

/// True when EVERY budget/goal row in the payload already carries a non-empty
/// `currency` — i.e. the payload is NOT the legacy currency-less shape.
bool _snapshotPlanningCarriesCurrency(Map<String, dynamic> tables) {
  bool has(String table) {
    final rows = (tables[table] as List<dynamic>? ?? const [])
        .cast<Map<String, dynamic>>();
    if (rows.isEmpty) return true; // nothing to disambiguate for this table
    return rows.every((r) {
      final c = r['currency'];
      return c is String && c.isNotEmpty;
    });
  }

  return has('budgets') && has('goals');
}

/// MALI-026 (Phase-8 B8-2.10 §5/§6/§7) — the restore preflight decision over a
/// snapshot, GATED on the live cutover state.
///
/// * The live DB is legacy (schema v29 today) -> [RestoreReady]: restoring
///   currency-less planning rows into a legacy DB is not ambiguous, so restore
///   proceeds exactly as before. THIS IS WHY v29 restore is unchanged.
/// * The live DB is canonical (future P3) and the payload's budgets/goals lack a
///   stable currency -> [RestorePlanningCurrencyRepairRequired], UNLESS a fresh,
///   payload-scoped [decision] (matching this payload's fingerprint) is supplied,
///   in which case restore may continue using that mapping (§7 continuation). A
///   decision whose fingerprint does not match (e.g. a LIVE_DATASET decision) does
///   NOT satisfy the payload (§6 cross-scope rejection).
RestorePreflightResult inspectRestoreSnapshotPlanning({
  required Map<String, dynamic> tables,
  required PlanningCutoverState cutoverState,
  RestorePayloadRepairDecision? decision,
}) {
  if (cutoverState != PlanningCutoverState.canonical) {
    return const RestoreReady();
  }
  final rows = restoreSnapshotPlanningRows(tables);
  final base = inspectPlanningRestorePayload(
    planningRows: rows,
    rowsLackCurrency: !_snapshotPlanningCarriesCurrency(tables),
  );
  if (base is RestorePlanningCurrencyRepairRequired &&
      decision != null &&
      decision.payloadFingerprint == base.payloadFingerprint) {
    return const RestoreReady();
  }
  return base;
}
