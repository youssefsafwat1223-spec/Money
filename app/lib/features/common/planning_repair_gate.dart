import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/di/app_providers.dart';
import '../../data/db/planning_cutover.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/qirsh_visuals.dart';
import '../../core/utils/l10n_ext.dart';

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
    final c = context.colors;
    return Directionality(
      textDirection: Directionality.of(context),
      child: Scaffold(
        key: const Key('planning_repair_required_view'),
        backgroundColor: c.bg,
        body: SafeArea(
          child: LayoutBuilder(builder: (context, constraints) =>
            SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.gutter),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 480),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const QirshIllustration(name: 'dataTransfer'),
                          const SizedBox(height: AppSpacing.s6),
                          Text(
                            context.l10n.prgTitle,
                            style: AppTypography.title1(c.textPrimary),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: AppSpacing.s3),
                          Text(
                            context.l10n.prgBody,
                            style: AppTypography.body(c.textSecondary),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: AppSpacing.s6),
                          FilledButton(
                            key: const Key('planning_repair_confirm_cta'),
                            onPressed: () =>
                                context.push('/settings/planning-currency-repair'),
                            child: Text(context.l10n.prgConfirmNow),
                          ),
                          const SizedBox(height: AppSpacing.s2),
                          TextButton(
                            key: const Key('planning_repair_defer_cta'),
                            onPressed: () =>
                                context.canPop() ? context.pop() : context.go('/'),
                            child: Text(context.l10n.prgNotNow),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
