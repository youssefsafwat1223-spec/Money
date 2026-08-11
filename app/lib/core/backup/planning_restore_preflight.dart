import 'dart:convert';

import 'package:crypto/crypto.dart';

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
