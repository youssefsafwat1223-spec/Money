import 'package:flutter/material.dart';
import '../common/money_text.dart';
import '../../domain/finance/goal_pacing.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/calm_page_header.dart';
import '../../core/theme/widgets/liquid_bar.dart';
import '../../core/theme/widgets/mali_card.dart';
import '../../core/utils/category_glyph.dart';
import '../../core/utils/currency.dart';
import '../../core/utils/formatters.dart';
import '../../domain/entities/goal_entity.dart';
import '../../domain/finance/money.dart';
import '../common/planning_repair_gate.dart';
import '../common/premium_loading.dart';
import 'goal_details_screen.dart';
import 'goal_form_screen.dart';
import 'goals_providers.dart';
import '../../core/utils/app_lucide_icons.dart';

class GoalsScreen extends ConsumerWidget {
  const GoalsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      PlanningRepairGate(child: _buildScreen(context, ref));

  Widget _buildScreen(BuildContext context, WidgetRef ref) {
    final async = ref.watch(goalsListProvider);
    final displayCurrency =
        ref.watch(baseCurrencyProvider).valueOrNull ?? 'SAR';
    final currencyLabel = Currency.arabicLabel(displayCurrency);

    return Scaffold(
      backgroundColor: context.colors.bg,
      body: async.when(
        skipLoadingOnReload: true,
        loading: () => const SkeletonList(rows: 4),
        error: (error, _) => const Center(child: Text('حدث خطأ')),
        data: (goals) {
          final visibleGoals = goals
              .where((goal) =>
                  goal.currency.toUpperCase() == displayCurrency.toUpperCase())
              .toList(growable: false);
          final saved = Money.sum(
              visibleGoals.map((goal) => goal.savedMoney), displayCurrency);
          final target = Money.sum(
              visibleGoals.map((goal) => goal.targetMoney), displayCurrency);
          if (visibleGoals.isEmpty) {
            return ListView(
              padding: EdgeInsets.zero,
              children: [
                _GoalsHeader(
                  count: 0,
                  saved: 0,
                  target: 0,
                  currencyLabel: currencyLabel,
                  onAdd: () => GoalFormScreen.showSheet(context),
                ),
                Padding(
                  padding: const EdgeInsets.all(AppSpacing.gutter),
                  child: _EmptyGoalsCard(
                    onAdd: () => GoalFormScreen.showSheet(context),
                  ),
                ),
              ],
            );
          }
          return RefreshIndicator(
            onRefresh: () async => refreshGoals(ref),
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                _GoalsHeader(
                  count: visibleGoals.length,
                  saved: saved.toDouble(),
                  target: target.toDouble(),
                  currencyLabel: currencyLabel,
                  onAdd: () => GoalFormScreen.showSheet(context),
                ),
                Padding(
                  padding: const EdgeInsets.all(AppSpacing.gutter),
                  child: Column(
                    children: [
                      for (final goal in visibleGoals) ...[
                        _GoalCard(
                          goal: goal,
                          currencyLabel: Currency.arabicLabel(goal.currency),
                        ),
                        const SizedBox(height: AppSpacing.s4),
                      ],
                      const SizedBox(height: 120),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _GoalCard extends StatelessWidget {
  const _GoalCard({
    required this.goal,
    required this.currencyLabel,
  });

  final GoalEntity goal;
  final String currencyLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final progress =
        goal.targetAmount == 0 ? 0.0 : goal.savedAmount / goal.targetAmount;
    final clampedProgress = progress.clamp(0, 1).toDouble();
    final percent = (progress * 100).round();
    final remaining =
        (goal.targetAmount - goal.savedAmount).clamp(0, double.infinity);
    // UX-025 — exact minor-unit arithmetic; the double above is display-only.
    final pacing = goalPacing(
      target: goal.targetMoney,
      saved: goal.savedMoney,
      deadline: goal.deadline,
      now: DateTime.now(),
    );
    // نفس لغة ويدجت الهدف في الداشبورد (design-system §15.9): كارت هادي +
    // تايل أخضر + كبسولة نسبة + شريط سائل — بدل التدرّج الكحلي القديم.
    final tone = remaining == 0 ? c.success : c.income;
    return MaliCard(
      style: MaliSurfaceStyle.floating,
      padding: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.xxxl),
        onTap: () => GoalDetailsScreen.showSheet(context, goal.id),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.s4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: tone.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: CategoryGlyph(
                      name: 'piggy-bank',
                      size: 20,
                      color: tone,
                    ),
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(goal.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTypography.cardTitle(c.textMain)),
                        const SizedBox(height: 2),
                        Text(
                          remaining == 0
                              ? 'اكتمل الهدف'
                              : 'باقي ${Formatters.integer(remaining)} $currencyLabel للوصول',
                          style: AppTypography.footnote(
                            remaining == 0 ? c.success : c.textLight,
                          ),
                        ),
                        // UX-025 — the date and the rate that make a goal a
                        // PLAN rather than a number.
                        //
                        // `deadline` was already stored, already used to order
                        // the Home preview, and already printed in the exported
                        // PDF — and never shown on the screen where the user
                        // manages the goal. The required monthly contribution
                        // is derivable from data already present and was never
                        // shown either.
                        //
                        // Subscriptions renders «بعد 3 يوم» and the installment
                        // card «القسط القادم: بعد 7 يوم»: time-to-target was
                        // surfaced for obligations and withheld from goals.
                        if (pacing.requiredPerMonth case final rate?) ...[
                          const SizedBox(height: 3),
                          Row(
                            children: [
                              Icon(AppLucideIcons.calendarDays,
                                  size: 12, color: c.textLight),
                              const SizedBox(width: 3),
                              Flexible(
                                child: Text(
                                  _goalDeadlineLabel(pacing.daysRemaining),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTypography.caption(c.textLight),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text('·',
                                  style: AppTypography.caption(c.textLight)),
                              const SizedBox(width: 6),
                              MoneyText(rate,
                                  style: AppTypography.caption(c.income)),
                              const SizedBox(width: 3),
                              Text('/شهر',
                                  style: AppTypography.caption(c.textLight)),
                            ],
                          ),
                        ] else if (pacing.isOverdue) ...[
                          const SizedBox(height: 3),
                          Text('تجاوز الموعد المستهدف',
                              style: AppTypography.caption(c.warning)),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                    decoration: BoxDecoration(
                      color: tone.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                    ),
                    child: Text('$percent%', style: AppTypography.label(tone)),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              LiquidBar(value: clampedProgress, color: tone),
              const SizedBox(height: 9),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'مدخر ${Formatters.integer(goal.savedAmount)} $currencyLabel',
                      style: AppTypography.caption(c.textSecondary),
                    ),
                  ),
                  Text(
                    'الهدف ${Formatters.integer(goal.targetAmount)} $currencyLabel',
                    style: AppTypography.caption(c.textSecondary),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GoalsHeader extends StatelessWidget {
  const _GoalsHeader({
    required this.count,
    required this.saved,
    required this.target,
    required this.currencyLabel,
    required this.onAdd,
  });

  final int count;
  final double saved;
  final double target;
  final String currencyLabel;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final ratio = target == 0 ? 0 : (saved / target * 100).round();
    return CalmPageHeader(
      title: 'الأهداف',
      subtitle: 'إجمالي المدخر لكل أحلامك',
      leading: Navigator.of(context).canPop()
          ? const BackButton(color: Colors.white)
          : null,
      trailing: GestureDetector(
        onTap: onAdd,
        child: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white.withValues(alpha: 0.16),
            border: Border.all(color: Colors.white.withValues(alpha: 0.28)),
          ),
          child: const Icon(AppLucideIcons.plus, color: Colors.white, size: 24),
        ),
      ),
      amount: Formatters.amount(saved),
      currency: currencyLabel,
      metrics: [
        CalmMetric(label: 'أهداف نشطة', value: '$count'),
        CalmMetric(label: 'نسبة التقدم', value: '$ratio%'),
        CalmMetric(label: 'المستهدف', value: Formatters.amount(target)),
      ],
    );
  }
}

class _EmptyGoalsCard extends StatelessWidget {
  const _EmptyGoalsCard({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SizedBox(
      width: double.infinity,
      child: MaliCard(
        style: MaliSurfaceStyle.floating,
        padding: const EdgeInsets.all(AppSpacing.s6),
        child: Column(
          children: [
            Text('أضف هدفك الأول وابدأ تعبئة الخزنة.',
                textAlign: TextAlign.center,
                style: AppTypography.callout(c.textLight)),
            const SizedBox(height: AppSpacing.s4),
            FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(AppLucideIcons.plus),
              label: const Text('إضافة هدف'),
            ),
          ],
        ),
      ),
    );
  }
}


/// UX-025 — time to target, in the same voice Subscriptions already uses
/// («بعد 3 يوم»), so the two surfaces read as one product.
String _goalDeadlineLabel(int days) {
  if (days == 0) return 'الموعد اليوم';
  if (days == 1) return 'باقي يوم';
  if (days == 2) return 'باقي يومان';
  if (days < 11) return 'باقي $days أيام';
  if (days < 60) return 'باقي $days يوم';
  final months = (days / 30).round();
  return months == 1 ? 'باقي شهر' : 'باقي $months شهر';
}
