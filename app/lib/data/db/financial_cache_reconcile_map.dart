import 'app_database.dart';
import 'financial_cache_health.dart';

/// Reconciliation pull domains (one pull cursor-family each).
const String kReconcileDomainAccounts = 'accounts';
const String kReconcileDomainLedger = 'ledger';
const String kReconcileDomainPlanning = 'planning';
const String kReconcileDomainSmartInbox = 'smart_inbox';

/// The authoritative, typed mapping of ONE supported legacy financial-cache
/// dirty marker (a `financial_cache_health.entity_type`) to how it is
/// reconciled: its pull domain, the singular planning pull-entity (planning
/// only), the persisted cursor key, and the completion signal used to clear it.
class FinancialCacheMarkerSpec {
  const FinancialCacheMarkerSpec({
    required this.marker,
    required this.domain,
    required this.cursorKey,
    required this.completionSignal,
    this.planningPullEntity,
  });

  /// The `financial_cache_health.entity_type` value (plural for planning).
  final String marker;

  /// Which reconciliation pull domain owns this marker.
  final String domain;

  /// PlanningPullService's SINGULAR entity type (e.g. 'budget') for planning
  /// markers; null for single-entity domains (accounts/ledger/smart_inbox).
  final String? planningPullEntity;

  /// The persisted `sync_cursors.entity` key reset to epoch for reconciliation.
  final String cursorKey;

  /// Human-readable note of the completion signal that permits clearing.
  final String completionSignal;
}

// Planning pull-entity strings are PlanningOutboxQueue.<x>EntityType (SINGULAR).
// Hardcoded here to keep this data-layer map free of a features/ import; a test
// (financial_cache_reconcile_map_test.dart) asserts they still equal the
// PlanningOutboxQueue constants so drift is caught.
const String _planBudget = 'budget';
const String _planGoal = 'goal';
const String _planSubscription = 'subscription';
const String _planPlan = 'plan';

/// Every supported historical marker maps here exactly once. A marker NOT in
/// this map is unsupported/unrecognized: it must be kept dirty and reported as a
/// failed/unsupported reconciliation — never guessed at and never cleared.
const Map<String, FinancialCacheMarkerSpec> kFinancialCacheMarkers = {
  accountsCacheEntityType: FinancialCacheMarkerSpec(
    marker: accountsCacheEntityType,
    domain: kReconcileDomainAccounts,
    cursorKey: 'accounts',
    completionSignal: 'AccountsPullResult.status == completed',
  ),
  transactionsCacheEntityType: FinancialCacheMarkerSpec(
    marker: transactionsCacheEntityType,
    domain: kReconcileDomainLedger,
    cursorKey: 'ledger_transactions',
    completionSignal: 'LedgerSyncResult.status == completed',
  ),
  budgetsCacheEntityType: FinancialCacheMarkerSpec(
    marker: budgetsCacheEntityType,
    domain: kReconcileDomainPlanning,
    planningPullEntity: _planBudget,
    cursorKey: 'planning_$_planBudget',
    completionSignal: "PlanningPullResult.completedEntities contains '$_planBudget'",
  ),
  goalsCacheEntityType: FinancialCacheMarkerSpec(
    marker: goalsCacheEntityType,
    domain: kReconcileDomainPlanning,
    planningPullEntity: _planGoal,
    cursorKey: 'planning_$_planGoal',
    completionSignal: "PlanningPullResult.completedEntities contains '$_planGoal'",
  ),
  subscriptionsCacheEntityType: FinancialCacheMarkerSpec(
    marker: subscriptionsCacheEntityType,
    domain: kReconcileDomainPlanning,
    planningPullEntity: _planSubscription,
    cursorKey: 'planning_$_planSubscription',
    completionSignal:
        "PlanningPullResult.completedEntities contains '$_planSubscription'",
  ),
  plansCacheEntityType: FinancialCacheMarkerSpec(
    marker: plansCacheEntityType,
    domain: kReconcileDomainPlanning,
    planningPullEntity: _planPlan,
    cursorKey: 'planning_$_planPlan',
    completionSignal: "PlanningPullResult.completedEntities contains '$_planPlan'",
  ),
  smartInboxCacheEntityType: FinancialCacheMarkerSpec(
    marker: smartInboxCacheEntityType,
    domain: kReconcileDomainSmartInbox,
    cursorKey: 'smart_inbox',
    completionSignal: 'SmartInboxSyncResult.status == completed',
  ),
};

/// Spec for a marker, or null if the marker is unsupported/unrecognized (which
/// callers MUST treat as unsupported — keep dirty, never clear).
FinancialCacheMarkerSpec? reconcileSpecForMarker(String marker) =>
    kFinancialCacheMarkers[marker];

/// Dirty markers that NO supported factory recognizes (requirement 3). They are
/// left dirty, never mapped to a guessed domain, and surfaced for diagnostics.
/// Known domains still reconcile/sync normally; the presence of an unsupported
/// marker never makes the overall state look globally clean.
Future<Set<String>> unsupportedDirtyMarkers(AppDatabase db) async {
  final dirty = await readDirtyFinancialCacheMarkers(db);
  return dirty.where((m) => reconcileSpecForMarker(m) == null).toSet();
}

/// Reverse map: a planning SINGULAR pull-entity (from
/// PlanningPullResult.completedEntities) back to its PLURAL cache marker, so a
/// completed planning entity clears exactly the right marker.
String? planningMarkerForPullEntity(String planningPullEntity) {
  for (final spec in kFinancialCacheMarkers.values) {
    if (spec.planningPullEntity == planningPullEntity) return spec.marker;
  }
  return null;
}
