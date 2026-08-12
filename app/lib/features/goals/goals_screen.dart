import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/calm_page_header.dart';
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
        loading: () => const FirstLoadPlaceholder(cardCount: 4),
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
                          currencyLabel:
                              Currency.arabicLabel(goal.currency),
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
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.card),
      onTap: () => GoalDetailsScreen.showSheet(context, goal.id),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.s4),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topRight,
            end: Alignment.bottomLeft,
            colors: [
              c.surface,
              Color.lerp(c.surface, c.primary, 0.09)!,
            ],
          ),
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: c.primary.withValues(alpha: 0.22)),
          boxShadow: [
            BoxShadow(
              color: c.primary.withValues(alpha: 0.08),
              blurRadius: 24,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: Column(
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: c.primary,
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                  child: const CategoryGlyph(
                    name: 'piggy-bank',
                    size: 24,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(width: AppSpacing.s3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(goal.name,
                          style: AppTypography.cardTitle(c.textMain)),
                      const SizedBox(height: AppSpacing.s1),
                      Text(
                        remaining == 0
                            ? 'اكتمل الهدف'
                            : 'باقي ${Formatters.integer(remaining)} $currencyLabel للوصول',
                        style: AppTypography.footnote(
                          remaining == 0 ? c.success : c.textLight,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.s3,
                    vertical: AppSpacing.s1,
                  ),
                  decoration: BoxDecoration(
                    color: c.primary.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                  child: Text(
                    '$percent%',
                    style: AppTypography.bodyStrong(c.primary),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.s4),
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.pill),
              child: LinearProgressIndicator(
                value: clampedProgress,
                minHeight: 10,
                backgroundColor: c.surface2,
                valueColor: AlwaysStoppedAnimation(
                  remaining == 0 ? c.success : c.primary,
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.s4),
            Container(
              padding: const EdgeInsets.all(AppSpacing.s3),
              decoration: BoxDecoration(
                color: c.bg.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: _GoalAmountTile(
                      label: 'مدخر',
                      value:
                          '${Formatters.integer(goal.savedAmount)} $currencyLabel',
                      color: c.success,
                    ),
                  ),
                  Container(width: 1, height: 34, color: c.border),
                  Expanded(
                    child: _GoalAmountTile(
                      label: 'الهدف',
                      value:
                          '${Formatters.integer(goal.targetAmount)} $currencyLabel',
                      color: c.textMain,
                    ),
                  ),
                  Container(width: 1, height: 34, color: c.border),
                  Expanded(
                    child: _GoalAmountTile(
                      label: 'النسبة',
                      value: '$percent%',
                      color: remaining == 0 ? c.success : c.primary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GoalAmountTile extends StatelessWidget {
  const _GoalAmountTile({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      children: [
        Text(label, style: AppTypography.caption(c.textLight)),
        const SizedBox(height: 2),
        Text(
          value,
          textAlign: TextAlign.center,
          style: AppTypography.subhead(color),
        ),
      ],
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
          child: const Icon(Icons.add_rounded, color: Colors.white, size: 24),
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
              icon: const Icon(Icons.add),
              label: const Text('إضافة هدف'),
            ),
          ],
        ),
      ),
    );
  }
}
