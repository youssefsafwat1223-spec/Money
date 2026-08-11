import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/planning_cutover.dart';

void main() {
  test('schema-v29 production coordinator always resolves to legacy', () {
    const coordinator = SchemaV29PlanningCutoverCoordinator();

    expect(coordinator.state(), PlanningCutoverState.legacy);
  });

  test('fixed coordinator exposes injected future states without a DB marker',
      () {
    for (final state in PlanningCutoverState.values) {
      expect(FixedPlanningCutoverCoordinator(state).state(), state);
    }
  });
}
