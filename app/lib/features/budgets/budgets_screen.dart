import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../domain/entities/goal_entity.dart';
import '../../domain/entities/engagement_entities.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../common/category_catalog.dart';
import '../common/premium_loading.dart';
import '../common/app_screen_scaffold.dart';
import '../common/app_header.dart';
import '../common/app_pill_tab_bar.dart';
import '../common/app_card.dart';
import '../common/app_empty_state.dart';
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

    return AppScreenScaffold(
      header: AppHeader(
        title: tab == 0 ? 'الميزانيات' : 'الأهداف',
        showBack: false,
        action: IconButton(
          onPressed: () {
            if (tab == 0) {
              BudgetFormScreen.showSheet(context);
            } else {
              GoalFormScreen.showSheet(context);
            }
          },
          icon: const Icon(AppLucideIcons.plus),
        ),
      ),
      body: async.when(
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
          final saved = data.goals.fold<double>(0, (sum, goal) => sum + goal.savedAmount);
          final target = data.goals.fold<double>(0, (sum, goal) => sum + goal.targetAmount);
          final progress = target == 0 ? 0 : (saved / target * 100).round();

          return RefreshIndicator(
            onRefresh: () async => refreshBudgets(ref),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.gutter,
                AppSpacing.s2,
                AppSpacing.gutter,
                120,
              ),
              children: [
                if (tab == 0)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.s4),
                    child: Text(
                      'حدود واضحة لكل تصنيف بدون ما يدخل الدخل في المصروف.',
                      style: AppTypography.callout(context.colors.textLight),
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.s4),
                    child: Text(
                      'خطط ادخارك جنب الميزانيات في مكان واحد.',
                      style: AppTypography.callout(context.colors.textLight),
                    ),
                  ),
                
                AppPillTabBar(
                  tabs: const ['الميزانيات', 'الأهداف'],
                  selectedIndex: tab,
                  onSelected: (value) => ref.read(budgetsPageTabProvider.notifier).state = value,
                ),
                const SizedBox(height: AppSpacing.s4),
                
                // Metrics
                Container(
                  padding: const EdgeInsets.all(AppSpacing.s4),
                  decoration: BoxDecoration(
                    color: context.colors.surface2,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    children: tab == 0
                        ? [
                            Expanded(child: _MetricItem(label: 'ميزانيات', value: '${data.snapshot.entries.length}')),
                            Container(width: 1, height: 32, color: context.colors.border),
                            Expanded(child: _MetricItem(label: 'مستخدم', value: '$usedRatio%')),
                            Container(width: 1, height: 32, color: context.colors.border),
                            Expanded(child: _MetricItem(label: 'إجمالي الحدود', value: '${Formatters.integer(limit)} ر')),
                          ]
                        : [
                            Expanded(child: _MetricItem(label: 'أهداف', value: '${data.goals.length}')),
                            Container(width: 1, height: 32, color: context.colors.border),
                            Expanded(child: _MetricItem(label: 'إنجاز', value: '$progress%')),
                            Container(width: 1, height: 32, color: context.colors.border),
                            Expanded(child: _MetricItem(label: 'مدخر', value: '${Formatters.integer(saved)} ر')),
                          ],
                  ),
                ),
                const SizedBox(height: AppSpacing.s6),

                if (tab == 0) ...[
                  if (data.snapshot.entries.isEmpty)
                    AppEmptyState(
                      icon: AppLucideIcons.pieChart,
                      title: 'لا توجد ميزانيات',
                      subtitle: 'أنشئ أول ميزانية يومية أو أسبوعية أو شهرية لتبدأ المتابعة.',
                      primaryLabel: 'إضافة ميزانية',
                      onPrimary: () => BudgetFormScreen.showSheet(context),
                    )
                  else
                    for (final entry in data.snapshot.entries) ...[
                      _BudgetCard(
                        entry: entry,
                        category: data.catalog.byId(entry.budget.categoryId),
                        accountName: data.accountName(entry.budget.accountId),
                      ),
                      const SizedBox(height: AppSpacing.s4),
                    ]
                ] else ...[
                  if (data.goals.isEmpty)
                    AppEmptyState(
                      icon: AppLucideIcons.target,
                      title: 'لا توجد أهداف',
                      subtitle: 'أضف هدف ادخار عشان مالي يتابع تقدمك جنب ميزانياتك.',
                      primaryLabel: 'إضافة هدف',
                      onPrimary: () => GoalFormScreen.showSheet(context),
                    )
                  else
                    for (final goal in data.goals) ...[
                      _GoalPlannerCard(goal: goal),
                      const SizedBox(height: AppSpacing.s4),
                    ]
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

class _MetricItem extends StatelessWidget {
  const _MetricItem({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(value, style: AppTypography.title2(context.colors.textPrimary)),
        const SizedBox(height: 2),
        Text(label, style: AppTypography.caption(context.colors.textMuted)),
      ],
    );
  }
}

class _BudgetCard extends StatelessWidget {
  const _BudgetCard({
    required this.entry,
    required this.category,
    required this.accountName,
  });

  final BudgetProgressEntry entry;
  final CategoryView? category;
  final String accountName;

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
    return AppCard(
      onTap: () => BudgetFormScreen.showSheet(
        context,
        budgetId: entry.budget.id,
      ),
      padding: const EdgeInsets.all(AppSpacing.s4),
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
                  color: (category?.color ?? progressColor).withValues(alpha: 0.14),
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
                      isGeneral ? 'كل المصروفات' : category?.nameAr ?? 'تصنيف',
                      style: AppTypography.headline(c.textPrimary),
                    ),
                    const SizedBox(height: AppSpacing.s1),
                    Row(
                      children: [
                        Text(
                          'ميزانية $periodLabel',
                          style: AppTypography.footnote(c.textSecondary),
                        ),
                        if (accountName.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: c.primary.withValues(alpha: 0.10),
                              borderRadius: BorderRadius.circular(AppRadius.pill),
                            ),
                            child: Text(
                              accountName,
                              style: AppTypography.caption(c.primary).copyWith(fontSize: 10),
                            ),
                          ),
                        ],
                        if (entry.budget.showOnHeader) ...[
                          const SizedBox(width: 6),
                          Icon(Icons.push_pin_outlined, size: 12, color: c.accent),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${entry.periodStart.day}/${entry.periodStart.month} — ${entry.periodEnd.day}/${entry.periodEnd.month}',
                      style: AppTypography.footnote(c.textSecondary).copyWith(fontSize: 10),
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
                    color: c.textPrimary,
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
                    color: c.textPrimary,
                  ),
                ),
              ],
            ),
          ),
        ],
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
    final progress = goal.targetAmount == 0 ? 0.0 : goal.savedAmount / goal.targetAmount;
    final percent = (progress * 100).round();
    final remaining = (goal.targetAmount - goal.savedAmount).clamp(0, double.infinity);
    
    return AppCard(
      onTap: () => GoalDetailsScreen.showSheet(context, goal.id),
      padding: const EdgeInsets.all(AppSpacing.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.savings_outlined, color: c.primary),
              const SizedBox(width: AppSpacing.s2),
              Expanded(
                child: Text(goal.name, style: AppTypography.headline(c.textPrimary)),
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
              remaining == 0 ? c.success : c.textSecondary,
            ),
          ),
        ],
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
        Text(label, style: AppTypography.caption(c.textSecondary)),
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
