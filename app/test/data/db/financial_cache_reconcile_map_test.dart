import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/financial_cache_health.dart';
import 'package:money_companion/data/db/financial_cache_reconcile_map.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';

// Batch-3 constraint 1: the marker <-> pull-entity mapping is explicit, typed,
// exhaustive, and bidirectional for planning. Unknown markers are never mapped.

void main() {
  test('every financial_cache_health marker maps exactly once', () {
    const allMarkers = {
      accountsCacheEntityType,
      transactionsCacheEntityType,
      budgetsCacheEntityType,
      goalsCacheEntityType,
      subscriptionsCacheEntityType,
      plansCacheEntityType,
      smartInboxCacheEntityType,
    };
    expect(kFinancialCacheMarkers.keys.toSet(), allMarkers,
        reason: 'map must cover exactly the supported markers, no more/less');
    for (final entry in kFinancialCacheMarkers.entries) {
      expect(entry.value.marker, entry.key, reason: 'self-consistent key');
    }
  });

  test('planning pull-entity strings equal the PlanningOutboxQueue constants',
      () {
    expect(kFinancialCacheMarkers[budgetsCacheEntityType]!.planningPullEntity,
        PlanningOutboxQueue.budgetsEntityType);
    expect(kFinancialCacheMarkers[goalsCacheEntityType]!.planningPullEntity,
        PlanningOutboxQueue.goalsEntityType);
    expect(
        kFinancialCacheMarkers[subscriptionsCacheEntityType]!.planningPullEntity,
        PlanningOutboxQueue.subscriptionsEntityType);
    expect(kFinancialCacheMarkers[plansCacheEntityType]!.planningPullEntity,
        PlanningOutboxQueue.plansEntityType);
  });

  test('single-entity domains have no planning pull-entity', () {
    for (final marker in [
      accountsCacheEntityType,
      transactionsCacheEntityType,
      smartInboxCacheEntityType,
    ]) {
      expect(kFinancialCacheMarkers[marker]!.planningPullEntity, isNull);
    }
  });

  test('planning marker <-> pull-entity is bidirectional', () {
    for (final spec in kFinancialCacheMarkers.values) {
      final pe = spec.planningPullEntity;
      if (pe == null) continue;
      expect(planningMarkerForPullEntity(pe), spec.marker,
          reason: 'singular $pe must map back to plural ${spec.marker}');
    }
  });

  test('cursor keys are correct per domain', () {
    expect(kFinancialCacheMarkers[accountsCacheEntityType]!.cursorKey, 'accounts');
    expect(kFinancialCacheMarkers[transactionsCacheEntityType]!.cursorKey,
        'ledger_transactions');
    expect(kFinancialCacheMarkers[budgetsCacheEntityType]!.cursorKey,
        'planning_budget');
    expect(kFinancialCacheMarkers[smartInboxCacheEntityType]!.cursorKey,
        'smart_inbox');
  });

  test('unknown / unrecognized marker maps to null (never guessed)', () {
    expect(reconcileSpecForMarker('not_a_real_marker'), isNull);
    expect(reconcileSpecForMarker(''), isNull);
    expect(planningMarkerForPullEntity('budgets'), isNull,
        reason: 'plural is a marker, not a pull-entity');
    expect(planningMarkerForPullEntity('nope'), isNull);
  });
}
