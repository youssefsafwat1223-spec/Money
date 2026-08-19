// MALI-026 (Phase-9F-2 §3/§16) — providers binding the server NULL-currency repair
// service to the UI. These surface SERVER-originated unresolved planning rows
// (distinct from the local-legacy P1/P2 repair driven by
// planningCurrencyRepairProvider), so an owner can explicitly resolve them.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../core/session/app_session.dart';
import '../../features/planning_sync/services/planning_server_currency_repair.dart';
import '../../features/planning_sync/services/planning_unresolved_currency.dart';

final planningServerCurrencyRepairServiceProvider =
    Provider<PlanningServerCurrencyRepairService>((ref) {
  return PlanningServerCurrencyRepairService(
    db: ref.watch(appDatabaseProvider),
    // applyRepairedRow does not consult the capability gate — it applies ONE
    // authoritatively-repaired row through the canonical path, so reusing the
    // existing pull service is correct even while planning sync stays deferred.
    pull: ref.watch(planningPullServiceProvider),
    remote: const SupabasePlanningRepairRemote(),
    getAuthUserId: () => AppSession.instance.readLocalDataOwnerUid(),
  );
});

/// The server-originated unresolved-currency worklist (budgets + goals), oldest
/// first, refreshed whenever the local DB changes.
final serverUnresolvedPlanningItemsProvider =
    FutureProvider<List<PlanningRepairItem>>((ref) async {
  ref.watch(dbRevisionProvider);
  return ref.watch(planningServerCurrencyRepairServiceProvider).items();
});

/// The rollout convergence counts (client-side, owner-scoped).
final serverUnresolvedPlanningCountsProvider =
    FutureProvider<UnresolvedPlanningCurrencyCounts>((ref) async {
  ref.watch(dbRevisionProvider);
  return ref
      .watch(planningServerCurrencyRepairServiceProvider)
      .unresolvedCounts();
});
