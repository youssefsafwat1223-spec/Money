// MALI-026 (Phase-9F §16) — client-side unresolved-planning-currency telemetry,
// derived entirely from the durable local quarantine (parked_child_rows with
// reason 'unresolved_currency'). This is the convergence signal for rollout: it
// must trend to zero before the planning-currency capability is activated, and it
// is the data source the owner repair UI lists. Owner-scoped by construction (a
// device only ever holds its own owner's pulled rows) — never a cross-user count.
import '../../../data/db/app_database.dart';

const _budgetsTable = 'user_budgets';
const _goalsTable = 'user_goals';
const _reason = 'unresolved_currency';

/// Active unresolved-currency counts, split by planning parent.
class UnresolvedPlanningCurrencyCounts {
  const UnresolvedPlanningCurrencyCounts({
    required this.budgets,
    required this.goals,
  });

  final int budgets;
  final int goals;
  int get total => budgets + goals;
  bool get isEmpty => total == 0;
}

/// One quarantined planning row awaiting explicit owner currency resolution.
class UnresolvedPlanningCurrencyItem {
  const UnresolvedPlanningCurrencyItem({
    required this.entityType,
    required this.serverId,
    required this.firstSeenAt,
  });

  /// 'budget' or 'goal'.
  final String entityType;
  final String serverId;
  final String firstSeenAt;
}

/// Counts of unresolved budget/goal rows (the rollout convergence metric).
Future<UnresolvedPlanningCurrencyCounts> unresolvedPlanningCurrencyCounts(
    AppDatabase db) async {
  final rows = await db
      .customSelect(
        "SELECT table_name, COUNT(*) AS n FROM parked_child_rows "
        "WHERE reason = '$_reason' GROUP BY table_name;",
      )
      .get();
  var budgets = 0;
  var goals = 0;
  for (final r in rows) {
    final table = r.read<String>('table_name');
    final n = r.read<int>('n');
    if (table == _budgetsTable) budgets = n;
    if (table == _goalsTable) goals = n;
  }
  return UnresolvedPlanningCurrencyCounts(budgets: budgets, goals: goals);
}

/// The unresolved rows the owner repair UI lists (budgets + goals), oldest first.
Future<List<UnresolvedPlanningCurrencyItem>> unresolvedPlanningCurrencyItems(
    AppDatabase db) async {
  final rows = await db
      .customSelect(
        "SELECT table_name, server_id, first_seen_at FROM parked_child_rows "
        "WHERE reason = '$_reason' AND table_name IN ('$_budgetsTable', '$_goalsTable') "
        "ORDER BY first_seen_at ASC;",
      )
      .get();
  return [
    for (final r in rows)
      UnresolvedPlanningCurrencyItem(
        entityType:
            r.read<String>('table_name') == _budgetsTable ? 'budget' : 'goal',
        serverId: r.read<String>('server_id'),
        firstSeenAt: r.read<String>('first_seen_at'),
      ),
  ];
}
