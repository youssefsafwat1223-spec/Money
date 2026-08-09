import '../../data/db/financial_cache_health.dart';
import '../../data/db/financial_cache_reconcile_map.dart';
import '../../data/db/legacy_financial_cache_reconciler.dart';
import '../../data/sync/sync_cursor.dart';
import '../capture/services/smart_inbox_sync_service.dart';
import '../planning_sync/services/accounts_pull_service.dart';
import '../planning_sync/services/planning_pull_service.dart';

// MALI-034 in-slot wiring: build a ReconcileDomain from each real pull service,
// using the typed marker map (kFinancialCacheMarkers) for the plural-marker <->
// singular-planning-entity conversion. reconcileDomain (the tested primitive)
// runs these at each domain's existing post-push pull slot. (The ledger domain
// is built inline in LedgerSyncEngine to avoid an import cycle with its adapter.)

ReconcileDomain accountsReconcileDomain(AccountsPullService pull) =>
    ReconcileDomain(
      name: kReconcileDomainAccounts,
      entities: const {accountsCacheEntityType},
      isEnabled: () => true,
      runFromEpoch: ({required dirtyEntities, required isAdmitted}) async {
        final r =
            await pull.pull(from: const SyncCursor.epoch(), isAdmitted: isAdmitted);
        return r.status == SyncPullStatus.completed
            ? const {accountsCacheEntityType}
            : const <String>{};
      },
    );

ReconcileDomain smartInboxReconcileDomain(SmartInboxSyncService pull) =>
    ReconcileDomain(
      name: kReconcileDomainSmartInbox,
      entities: const {smartInboxCacheEntityType},
      isEnabled: () => true,
      runFromEpoch: ({required dirtyEntities, required isAdmitted}) async {
        final r =
            await pull.pull(from: const SyncCursor.epoch(), isAdmitted: isAdmitted);
        return r.status == SyncPullStatus.completed
            ? const {smartInboxCacheEntityType}
            : const <String>{};
      },
    );

/// Planning is per-entity: only the DIRTY planning markers restart from epoch
/// (mapped plural->singular); non-dirty siblings keep their incremental cursor
/// inside the same single planning pull. completedEntities (singular) map back
/// to the plural markers that may clear.
ReconcileDomain planningReconcileDomain(PlanningPullService pull) =>
    ReconcileDomain(
      name: kReconcileDomainPlanning,
      entities: const {
        budgetsCacheEntityType,
        goalsCacheEntityType,
        subscriptionsCacheEntityType,
        plansCacheEntityType,
      },
      isEnabled: () => true,
      runFromEpoch: ({required dirtyEntities, required isAdmitted}) async {
        final singular = dirtyEntities
            .map((m) => reconcileSpecForMarker(m)?.planningPullEntity)
            .whereType<String>()
            .toSet();
        final r =
            await pull.pull(fromEpochEntities: singular, isAdmitted: isAdmitted);
        return r.completedEntities
            .map(planningMarkerForPullEntity)
            .whereType<String>()
            .toSet();
      },
    );
