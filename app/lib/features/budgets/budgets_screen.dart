import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../domain/entities/goal_entity.dart';
import '../../domain/entities/engagement_entities.dart';
import '../../core/utils/formatters.dart';
import '../common/category_catalog.dart';
import '../common/premium_loading.dart';
import '../common/section_hero_header.dart';
import '../goals/goal_details_screen.dart';
import '../goals/goal_form_screen.dart';
import 'budget_form_screen.dart';
import 'budgets_providers.dart';

class BudgetsScreen extends ConsumerWidget {
  const BudgetsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(budgetsViewProvider);
    final tab = ref.watch(budgetsPageTabProvider);

    return async.when(
        loading: () => const PremiumSkeletonPage(cardCount: 4),
        error: (error, _) => Center(child: Text('حدث خطأ: $error')),
        data: (data) {
          final used = data.snapshot.entries.fold<double>(
            0,
            (sum, entry) => sum + entry.spent,
          );
          final limit = data.snapshot.entries.fold<double>(
            0,
            (sum, entry) => sum + entry.budget.amount,
          );
          final usedRatio = limit == 0 ? 0 : (used / limit * 100).round();
          final saved =
              data.goals.fold<double>(0, (sum, goal) => sum + goal.savedAmount);
          final target =
              data.goals.fold<double>(0, (sum, goal) => sum + goal.targetAmount);
          return RefreshIndicator(
            onRefresh: () async => refreshBudgets(ref),
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                tab == 0
                    ? _BudgetsHeader(
                        budgetCount: data.snapshot.entries.length,
                        usedRatio: usedRatio,
                        totalLimit: limit,
                        onAdd: () => BudgetFormScreen.showSheet(context),
                      )
                    : _GoalsHeader(
                        count: data.goals.length,
                        saved: saved,
                        target: target,
                        onAdd: () => GoalFormScreen.showSheet(context),
                      ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.gutter,
                    AppSpacing.s4,
                    AppSpacing.gutter,
                    0,
                  ),
                  child: _PlannerSegmented(
                    value: tab,
                    onChanged: (value) =>
                        ref.read(budgetsPageTabProvider.notifier).state = value,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(AppSpacing.gutter),
                  child: tab == 0
                      ? Column(
                          children: [
                            if (data.snapshot.entries.isEmpty)
                              _EmptyBudgetCard(
                                onAdd: () => BudgetFormScreen.showSheet(context),
                              )
                            else
                              for (final entry in data.snapshot.entries) ...[
                                _BudgetCard(
                                  entry: entry,
                                  category:
                                      data.catalog.byId(entry.budget.categoryId),
                                ),
                                const SizedBox(height: AppSpacing.s4),
                              ],
                            const SizedBox(height: 120),
                          ],
                        )
                      : Column(
                          children: [
                            if (data.goals.isEmpty)
                              _EmptyGoalsCard(
                                onAdd: () => GoalFormScreen.showSheet(context),
                              )
                            else
                              for (final goal in data.goals) ...[
                                _GoalPlannerCard(goal: goal),
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
      );
  }
}

class _PlannerSegmented extends StatelessWidget {
  const _PlannerSegmented({required this.value, required this.onChanged});

  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    const labels = ['الميزانيات', 'الأهداف'];
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++)
            Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(AppRadius.pill),
                onTap: () => onChanged(i),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  decoration: BoxDecoration(
                    color: value == i ? c.primary : Colors.transparent,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                  child: Text(
                    labels[i],
                    textAlign: TextAlign.center,
                    style: AppTypography.caption(
                      value == i ? Colors.white : c.textLight,
                    ).copyWith(fontWeight: FontWeight.w800),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _GoalsHeader extends StatelessWidget {
  const _GoalsHeader({
    required this.count,
    required this.saved,
    required this.target,
    required this.onAdd,
  });

  final int count;
  final double saved;
  final double target;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final progress = target == 0 ? 0 : (saved / target * 100).round();
    return SectionHeroHeader(
      title: 'الأهداف',
      subtitle: 'خطط ادخارك جنب الميزانيات في مكان واحد.',
      metrics: [
        SectionHeroMetric(value: '$count', label: 'أهداف'),
        SectionHeroMetric(value: '$progress%', label: 'إنجاز'),
        SectionHeroMetric(value: '${Formatters.integer(saved)} ر', label: 'مدخر'),
      ],
      action: FilledButton.icon(
        onPressed: onAdd,
        icon: const Icon(Icons.add),
        label: const Text('إضافة هدف'),
      ),
    );
  }
}

class _GoalPlannerCard extends StatelessWidget {
  const _GoalPlannerCard({required this.goal});

  final GoalEntity goal;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final progress =
        goal.targetAmount == 0 ? 0.0 : goal.savedAmount / goal.targetAmount;
    final percent = (progress * 100).round();
    final remaining =
        (goal.targetAmount - goal.savedAmount).clamp(0, double.infinity);
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.card),
      onTap: () => GoalDetailsScreen.showSheet(context, goal.id),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.s4),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: c.primary.withValues(alpha: 0.20)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.savings_outlined, color: c.primary),
                const SizedBox(width: AppSpacing.s2),
                Expanded(
                  child: Text(goal.name, style: AppTypography.headline(c.textMain)),
                ),
                Text('$percent%', style: AppTypography.bodyStrong(c.primary)),
              ],
            ),
            const SizedBox(height: AppSpacing.s3),
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.pill),
              child: LinearProgressIndicator(
                value: progress.clamp(0, 1).toDouble(),
                minHeight: 10,
                backgroundColor: c.surface2,
                valueColor: AlwaysStoppedAnimation(
                  remaining == 0 ? c.success : c.primary,
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.s3),
            Text(
              remaining == 0
                  ? 'اكتمل الهدف'
                  : 'باقي ${Formatters.integer(remaining)} ر للوصول',
              style: AppTypography.caption(
                remaining == 0 ? c.success : c.textLight,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyGoalsCard extends StatelessWidget {
  const _EmptyGoalsCard({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.s6),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: c.border),
      ),
      child: Column(
        children: [
          Text(
            'أضف هدف ادخار عشان مالي يتابع تقدمك جنب ميزانياتك.',
            textAlign: TextAlign.center,
            style: AppTypography.callout(c.textLight),
          ),
          const SizedBox(height: AppSpacing.s4),
          FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add),
            label: const Text('إضافة هدف'),
          ),
        ],
      ),
    );
  }
}

class _BudgetsHeader extends StatelessWidget {
  const _BudgetsHeader({
    required this.budgetCount,
    required this.usedRatio,
    required this.totalLimit,
    required this.onAdd,
  });

  final int budgetCount;
  final int usedRatio;
  final double totalLimit;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return SectionHeroHeader(
      title: 'الميزانيات',
      subtitle: 'حدود واضحة لكل تصنيف بدون ما يدخل الدخل في المصروف.',
      metrics: [
        SectionHeroMetric(value: '$budgetCount', label: 'ميزانيات'),
        SectionHeroMetric(value: '$usedRatio%', label: 'مستخدم'),
        SectionHeroMetric(
          value: '${Formatters.integer(totalLimit)} ر',
          label: 'إجمالي الحدود',
        ),
      ],
      action: FilledButton.icon(
        onPressed: onAdd,
        icon: const Icon(Icons.add),
        label: const Text('إضافة ميزانية'),
      ),
    );
  }
}

class _EmptyBudgetCard extends StatelessWidget {
  const _EmptyBudgetCard({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.s6),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: c.border),
      ),
      child: Column(
        children: [
          Text(
            'أنشئ أول ميزانية يومية أو أسبوعية أو شهرية لتبدأ المتابعة.',
            textAlign: TextAlign.center,
            style: AppTypography.callout(c.textLight),
          ),
          const SizedBox(height: AppSpacing.s4),
          FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add),
            label: const Text('إضافة ميزانية'),
          ),
        ],
      ),
    );
  }
}

class _BudgetCard extends StatelessWidget {
  const _BudgetCard({
    required this.entry,
    required this.category,
  });

  final BudgetProgressEntry entry;
  final CategoryView? category;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final progressColor = c.budgetState(entry.ratio);
    final progress = entry.ratio.clamp(0, 1).toDouble();
    final percent = (entry.ratio * 100).round();
    final isOver = entry.remaining < 0;
    final isGeneral = entry.budget.isAllExpenses;
    final statusLabel = isOver
        ? 'تجاوز'
        : entry.ratio >= 0.8
            ? 'اقتربت'
            : 'آمن';
    final periodLabel = switch (entry.budget.period) {
      _ => switch (entry.budget.period.name) {
          'daily' => 'يومي',
          'weekly' => 'أسبوعي',
          _ => 'شهري',
        }
    };
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.card),
      onTap: () => BudgetFormScreen.showSheet(
        context,
        budgetId: entry.budget.id,
      ),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.s4),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topRight,
            end: Alignment.bottomLeft,
            colors: [
              c.surface,
              Color.lerp(c.surface, progressColor, 0.08)!,
            ],
          ),
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: progressColor.withValues(alpha: 0.22)),
          boxShadow: [
            BoxShadow(
              color: progressColor.withValues(alpha: 0.08),
              blurRadius: 22,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 50,
                  height: 50,
                  decoration: BoxDecoration(
                    color: (category?.color ?? progressColor)
                        .withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                  child: Icon(
                    isGeneral
                        ? Icons.account_balance_wallet_outlined
                        : category?.icon ?? Icons.category_outlined,
                    color: category?.color ?? progressColor,
                  ),
                ),
                const SizedBox(width: AppSpacing.s3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isGeneral
                            ? 'كل المصروفات'
                            : category?.nameAr ?? 'تصنيف',
                        style: AppTypography.headline(c.textMain),
                      ),
                      const SizedBox(height: AppSpacing.s1),
                      Text(
                        'ميزانية $periodLabel',
                        style: AppTypography.footnote(c.textLight),
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
                    color: progressColor.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                  child: Text(
                    statusLabel,
                    style: AppTypography.caption(progressColor),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.s4),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '$percent%',
                  style: AppTypography.title2(progressColor),
                ),
                const SizedBox(width: AppSpacing.s2),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 5),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                      child: LinearProgressIndicator(
                        value: progress,
                        minHeight: 9,
                        backgroundColor: c.surface2,
                        valueColor: AlwaysStoppedAnimation(progressColor),
                      ),
                    ),
                  ),
                ),
              ],
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
                    child: _BudgetAmountTile(
                      label: 'مصروف',
                      value: '${Formatters.integer(entry.spent)} ر',
                      color: c.textMain,
                    ),
                  ),
                  Container(width: 1, height: 34, color: c.border),
                  Expanded(
                    child: _BudgetAmountTile(
                      label: isOver ? 'تجاوز' : 'باقي',
                      value: isOver
                          ? '${Formatters.integer(entry.remaining.abs())} ر'
                          : '${Formatters.integer(entry.remaining)} ر',
                      color: isOver ? c.danger : c.success,
                    ),
                  ),
                  Container(width: 1, height: 34, color: c.border),
                  Expanded(
                    child: _BudgetAmountTile(
                      label: 'الحد',
                      value: '${Formatters.integer(entry.budget.amount)} ر',
                      color: c.textMain,
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

class _BudgetAmountTile extends StatelessWidget {
  const _BudgetAmountTile({
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
      crossAxisAlignment: CrossAxisAlignment.center,
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
