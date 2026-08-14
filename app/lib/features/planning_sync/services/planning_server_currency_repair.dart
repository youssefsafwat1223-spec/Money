// MALI-026 (Phase-9F-2) — owner recoverability for SERVER-originated NULL-currency
// planning rows. The durable quarantine (parked_child_rows, reason
// 'unresolved_currency') is the source of repair work; the owner explicitly picks
// the true currency; a GUARDED owner-scoped first-writer-wins server UPDATE sets
// NULL→currency; then the row is re-pulled through the SAME canonical path and the
// quarantine clears only after a successful canonical apply. No currency is ever
// guessed; no CAS; no service_role; owner + RLS only.
import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/sync/guarded_mutation.dart';
import '../../../data/db/app_database.dart';
import '../../../data/db/sql_value_codec.dart';
import '../../../domain/finance/currency_scale.dart';
import 'planning_pull_service.dart';
import 'planning_unresolved_currency.dart';

/// A single owner repair task, with safe display context (no currency guess).
class PlanningRepairItem {
  const PlanningRepairItem({
    required this.entityType,
    required this.serverId,
    required this.firstSeenAt,
    this.title,
    this.amountText,
  });

  final String entityType; // 'budget' | 'goal'
  final String serverId;
  final String firstSeenAt;

  /// A display title (goal name); null when the entity has none (budget).
  final String? title;

  /// Exact monetary text for DISPLAY only (never a currency/authority source).
  final String? amountText;
}

enum PlanningRepairOutcome {
  resolved,
  resolvedByRemoval, // server row is gone → no canonical obligation
  failedKeepUnresolved, // network/server/decode/apply failure → quarantine kept
  unsupportedCurrency,
  notSignedIn,
  unknownEntity,
}

/// The narrow server surface the repair flow needs. Injectable (mirrors
/// PlanningRemoteSink/PlanningRemoteSource) so the guarded contract is testable
/// without a live client.
abstract class PlanningRepairRemote {
  /// Guarded owner-scoped first-writer-wins `NULL → currency` update. Returns the
  /// updated row (canonical pull projection) if THIS call set the currency, or
  /// `null` if it matched 0 rows (already resolved by another writer, or gone).
  Future<Map<String, dynamic>?> resolveCurrencyIfNull({
    required String table,
    required String serverId,
    required String userId,
    required String currency,
  });

  /// Authoritative refetch of the owner's row (canonical projection), or `null`
  /// if it no longer exists / is not owned.
  Future<Map<String, dynamic>?> refetchRow({
    required String table,
    required String serverId,
    required String userId,
  });
}

/// Real Supabase implementation of the guarded repair contract.
class SupabasePlanningRepairRemote implements PlanningRepairRemote {
  const SupabasePlanningRepairRemote();

  SupabaseClient get _client => Supabase.instance.client;

  @override
  Future<Map<String, dynamic>?> resolveCurrencyIfNull({
    required String table,
    required String serverId,
    required String userId,
    required String currency,
  }) async {
    // NULL→value only (currency IS NULL), owner-scoped (user_id), first-writer-
    // wins: a row already carrying a currency matches 0 rows and is never
    // overwritten. RLS additionally enforces ownership server-side.
    // MALI-026 (Phase-9M): decode the LIST (0/1/>1). 0 rows = another client
    // already resolved the currency (first-writer-wins) → null → caller refetches
    // the authoritative row. Never `.maybeSingle()` (PGRST116 on 0-row).
    final rows = await _client
        .from(table)
        .update({'currency': currency})
        .eq('id', serverId)
        .eq('user_id', userId)
        .isFilter('currency', null)
        .select(planningPullSelectForTable(table));
    return guardedAck(rows, 'planningRepair.resolveCurrencyIfNull[$table]');
  }

  @override
  Future<Map<String, dynamic>?> refetchRow({
    required String table,
    required String serverId,
    required String userId,
  }) async {
    final res = await _client
        .from(table)
        .select(planningPullSelectForTable(table))
        .eq('id', serverId)
        .eq('user_id', userId)
        .maybeSingle();
    return res == null ? null : Map<String, dynamic>.from(res);
  }
}

/// Orchestrates owner repair of a server NULL-currency planning row.
class PlanningServerCurrencyRepairService {
  PlanningServerCurrencyRepairService({
    required AppDatabase db,
    required PlanningPullService pull,
    required PlanningRepairRemote remote,
    required Future<String?> Function() getAuthUserId,
  })  : _db = db,
        _pull = pull,
        _remote = remote,
        _getAuthUserId = getAuthUserId;

  final AppDatabase _db;
  final PlanningPullService _pull;
  final PlanningRepairRemote _remote;
  final Future<String?> Function() _getAuthUserId;

  static const _tableFor = {'budget': 'user_budgets', 'goal': 'user_goals'};

  /// The rollout convergence metric (client-derived from the durable quarantine).
  Future<UnresolvedPlanningCurrencyCounts> unresolvedCounts() =>
      unresolvedPlanningCurrencyCounts(_db);

  /// The owner repair worklist with safe display context (no currency guess).
  Future<List<PlanningRepairItem>> items() async {
    final rows = await _db
        .customSelect(
          "SELECT table_name, server_id, row_json, first_seen_at "
          "FROM parked_child_rows WHERE reason = 'unresolved_currency' "
          "AND table_name IN ('user_budgets', 'user_goals') "
          "ORDER BY first_seen_at ASC;",
        )
        .get();
    return [
      for (final r in rows)
        _toItem(
          r.read<String>('table_name'),
          r.read<String>('server_id'),
          r.read<String>('row_json'),
          r.read<String>('first_seen_at'),
        ),
    ];
  }

  PlanningRepairItem _toItem(
      String table, String serverId, String rowJson, String firstSeenAt) {
    final isGoal = table == 'user_goals';
    Map<String, dynamic> row = const {};
    try {
      row = Map<String, dynamic>.from(jsonDecode(rowJson) as Map);
    } catch (_) {/* display context is best-effort only */}
    return PlanningRepairItem(
      entityType: isGoal ? 'goal' : 'budget',
      serverId: serverId,
      firstSeenAt: firstSeenAt,
      title: isGoal ? row['name'] as String? : null,
      amountText:
          (isGoal ? row['target_amount_text'] : row['amount_text']) as String?,
    );
  }

  /// Repair one row: guarded owner-scoped NULL→currency server write, then an
  /// authoritative canonical re-pull that clears the quarantine only on success.
  /// [currency] MUST be an explicit owner choice (never a default). Idempotent and
  /// fail-closed: any failure leaves the quarantine intact for a safe retry.
  Future<PlanningRepairOutcome> resolve({
    required String entityType,
    required String serverId,
    required String currency,
  }) async {
    final code = currency.trim().toUpperCase();
    if (code.isEmpty) return PlanningRepairOutcome.unsupportedCurrency;
    try {
      currencyScale(code); // supported-currency registry gate
    } on UnsupportedCurrencyException {
      return PlanningRepairOutcome.unsupportedCurrency;
    }
    final table = _tableFor[entityType];
    if (table == null) return PlanningRepairOutcome.unknownEntity;
    final uid = await _getAuthUserId();
    if (uid == null) return PlanningRepairOutcome.notSignedIn;

    Map<String, dynamic>? row;
    try {
      // First-writer-wins: our guarded update returns the row iff WE set it.
      row = await _remote.resolveCurrencyIfNull(
          table: table, serverId: serverId, userId: uid, currency: code);
      // 0 rows changed → someone else resolved it (or it's gone). Accept the
      // authoritative persisted state; NEVER overwrite another device's choice.
      row ??= await _remote.refetchRow(
          table: table, serverId: serverId, userId: uid);
    } catch (_) {
      return PlanningRepairOutcome.failedKeepUnresolved; // §8 keep quarantine
    }

    if (row == null) {
      // The server row is gone (hard-deleted / not owned) → no repair obligation.
      await _clearQuarantine(table, serverId);
      return PlanningRepairOutcome.resolvedByRemoval;
    }

    try {
      // §7: converge onto the SAME canonical apply path production sync uses.
      // Throws (quarantine kept, nothing applied) if the row is still non-canonical.
      await _pull.applyRepairedRow(entityType, row);
    } catch (_) {
      return PlanningRepairOutcome.failedKeepUnresolved; // §8 keep quarantine
    }
    return PlanningRepairOutcome.resolved;
  }

  Future<void> _clearQuarantine(String table, String serverId) =>
      _db.customStatement(
        'DELETE FROM parked_child_rows '
        'WHERE table_name = ${sqlString(table)} '
        'AND server_id = ${sqlString(serverId)} '
        "AND reason = 'unresolved_currency';",
      );
}
