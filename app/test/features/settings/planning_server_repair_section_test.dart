// MALI-026 (Phase-9F-2 §3/§4/§19 C,D) — the server-unresolved repair section
// surfaces quarantined rows and starts with NO preselected currency (the owner
// must choose). Renders nothing when there is no server repair work.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/features/planning_sync/services/planning_server_currency_repair.dart';
import 'package:money_companion/features/settings/planning_server_repair_providers.dart';
import 'package:money_companion/features/settings/planning_server_repair_section.dart';

void main() {
  testWidgets('surfaces items with NO preselected currency', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        serverUnresolvedPlanningItemsProvider.overrideWith((ref) async => const [
              PlanningRepairItem(
                entityType: 'goal',
                serverId: 'g1',
                firstSeenAt: 'x',
                title: 'goal-g1',
                amountText: '12.345',
              ),
            ]),
      ],
      child: const MaterialApp(
          home: Scaffold(body: PlanningServerRepairSection())),
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('server-unresolved-repair')), findsOneWidget);
    expect(find.textContaining('goal-g1'), findsOneWidget);
    // §4: the currency field starts EMPTY — never a preselected default.
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, isEmpty);
  });

  testWidgets('renders nothing when there is no server repair work',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        serverUnresolvedPlanningItemsProvider.overrideWith((ref) async => const []),
      ],
      child: const MaterialApp(
          home: Scaffold(body: PlanningServerRepairSection())),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('server-unresolved-repair')), findsNothing);
  });
}
