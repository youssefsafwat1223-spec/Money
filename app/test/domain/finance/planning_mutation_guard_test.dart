import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/data/db/planning_cutover.dart';
import 'package:money_companion/domain/finance/planning_mutation_guard.dart';

/// Illustrative repository boundary: its financial write can only happen after
/// the central guard returns successfully.
class _GuardedPlanningWrite {
  _GuardedPlanningWrite(this._guard);

  final PlanningMutationGuard _guard;
  var mutationCount = 0;
  var deletionCount = 0;

  void mutate() {
    _guard.requireMutable();
    mutationCount++;
  }

  void delete() {
    _guard.requireDeletable();
    deletionCount++;
  }
}

ProviderContainer _container(PlanningCutoverState state) {
  return ProviderContainer(
    overrides: [
      planningCutoverCoordinatorProvider.overrideWithValue(
        FixedPlanningCutoverCoordinator(state),
      ),
    ],
  );
}

void main() {
  test('legacy/v29 injected provider allows guarded repository mutation', () {
    final container = _container(PlanningCutoverState.legacy);
    addTearDown(container.dispose);
    final write = _GuardedPlanningWrite(
      container.read(planningMutationGuardProvider),
    );

    write.mutate();

    expect(write.mutationCount, 1);
  });

  test('canonical injected provider allows guarded mutation and deletion', () {
    final container = _container(PlanningCutoverState.canonical);
    addTearDown(container.dispose);
    final write = _GuardedPlanningWrite(
      container.read(planningMutationGuardProvider),
    );

    write.mutate();
    write.delete();

    expect(write.mutationCount, 1);
    expect(write.deletionCount, 1);
  });

  test(
      'unresolved injected provider throws typed error before repository write',
      () {
    final container = _container(PlanningCutoverState.unresolved);
    addTearDown(container.dispose);
    final write = _GuardedPlanningWrite(
      container.read(planningMutationGuardProvider),
    );

    expect(write.mutate, throwsA(isA<PlanningCurrencyRepairRequired>()));
    expect(write.mutationCount, 0);
  });

  test('unresolved delete is blocked because it changes repair fingerprint',
      () {
    final container = _container(PlanningCutoverState.unresolved);
    addTearDown(container.dispose);
    final write = _GuardedPlanningWrite(
      container.read(planningMutationGuardProvider),
    );

    expect(write.delete, throwsA(isA<PlanningCurrencyRepairRequired>()));
    expect(write.deletionCount, 0);
  });
}
