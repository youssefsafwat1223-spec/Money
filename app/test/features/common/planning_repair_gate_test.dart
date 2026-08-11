import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/data/db/planning_cutover.dart';
import 'package:money_companion/features/common/planning_repair_gate.dart';

// MALI-026 (Phase-8 B8-2.10 §3) — the planning navigation repair gate reacts to
// the ONE cutover coordinator. Legacy (v29) is a passthrough; unresolved shows a
// repair interstitial and keeps planning unavailable. Confirm routes to repair;
// defer returns to the rest of the app. App startup is never blocked (the gate is
// per-screen).

Override _coordinator(PlanningCutoverState s) => planningCutoverCoordinatorProvider
    .overrideWithValue(FixedPlanningCutoverCoordinator(s));

GoRouter _router() => GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (_, __) => const Text('HOME')),
        GoRoute(
          path: '/budgets',
          builder: (_, __) =>
              const PlanningRepairGate(child: Text('PLANNING_BODY')),
        ),
        GoRoute(
          path: '/settings/planning-currency-repair',
          builder: (_, __) => const Scaffold(body: Text('REPAIR_SCREEN')),
        ),
      ],
    );

Future<void> _pump(WidgetTester tester, PlanningCutoverState state,
    GoRouter router) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [_coordinator(state)],
    child: MaterialApp.router(routerConfig: router),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('legacy (v29) renders the child unchanged — no interstitial',
      (tester) async {
    final router = _router();
    router.go('/budgets');
    await _pump(tester, PlanningCutoverState.legacy, router);

    expect(find.text('PLANNING_BODY'), findsOneWidget);
    expect(find.byKey(const Key('planning_repair_required_view')), findsNothing);
  });

  testWidgets('canonical also passes through', (tester) async {
    final router = _router();
    router.go('/budgets');
    await _pump(tester, PlanningCutoverState.canonical, router);
    expect(find.text('PLANNING_BODY'), findsOneWidget);
  });

  testWidgets('unresolved shows the repair interstitial, not the planning body',
      (tester) async {
    final router = _router();
    router.go('/budgets');
    await _pump(tester, PlanningCutoverState.unresolved, router);

    expect(find.byKey(const Key('planning_repair_required_view')),
        findsOneWidget);
    expect(find.text('PLANNING_BODY'), findsNothing);
  });

  testWidgets('confirm navigates to the repair screen', (tester) async {
    final router = _router();
    router.go('/budgets');
    await _pump(tester, PlanningCutoverState.unresolved, router);

    await tester.tap(find.byKey(const Key('planning_repair_confirm_cta')));
    await tester.pumpAndSettle();
    expect(find.text('REPAIR_SCREEN'), findsOneWidget);
  });

  testWidgets('defer returns to the rest of the app (planning stays gated)',
      (tester) async {
    final router = _router();
    await _pump(tester, PlanningCutoverState.unresolved, router);
    // Push the gated planning route on top of HOME so a defer can pop back.
    router.push('/budgets');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('planning_repair_required_view')),
        findsOneWidget);

    await tester.tap(find.byKey(const Key('planning_repair_defer_cta')));
    await tester.pumpAndSettle();
    expect(find.text('HOME'), findsOneWidget);
    // Re-entering planning still shows the interstitial (still unavailable).
    router.push('/budgets');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('planning_repair_required_view')),
        findsOneWidget);
  });
}
