import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/di/app_providers.dart';
import '../../data/db/planning_cutover.dart';

/// MALI-026 (Phase-8 B8-2.10 §3) — the planning navigation repair gate.
///
/// Wraps the Budgets / Goals screens. It consumes the ONE
/// [planningCutoverCoordinatorProvider] seam:
///   * schema v29 (and any resolved/canonical state) -> renders [child]
///     unchanged, so today's navigation is untouched;
///   * future v30 `unresolved` (P1) -> renders a repair-required interstitial
///     instead of the planning surface, so planning stays UNAVAILABLE until the
///     user confirms the currency. Deferring returns them to the rest of the app;
///     it never blocks app startup (this gate is per-screen, not in bootstrap).
class PlanningRepairGate extends ConsumerWidget {
  const PlanningRepairGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(planningCutoverCoordinatorProvider).state();
    if (state != PlanningCutoverState.unresolved) return child;
    return const PlanningRepairRequiredView();
  }
}

/// The interstitial shown while planning is unavailable pending currency repair.
class PlanningRepairRequiredView extends StatelessWidget {
  const PlanningRepairRequiredView({super.key});

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        key: const Key('planning_repair_required_view'),
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.lock_clock_outlined, size: 48),
                  const SizedBox(height: 16),
                  const Text(
                    'التخطيط غير متاح مؤقتاً',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'قبل استخدام الميزانيات والأهداف، نحتاج تأكيد العملة التي '
                    'تُعامَل بها بيانات التخطيط الحالية. لن نغيّر أي مبلغ.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    key: const Key('planning_repair_confirm_cta'),
                    onPressed: () =>
                        context.push('/settings/planning-currency-repair'),
                    child: const Text('تأكيد العملة الآن'),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    key: const Key('planning_repair_defer_cta'),
                    onPressed: () =>
                        context.canPop() ? context.pop() : context.go('/'),
                    child: const Text('ليس الآن'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
