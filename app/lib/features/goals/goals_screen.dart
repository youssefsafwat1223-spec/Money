import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/currency.dart';
import '../../core/utils/formatters.dart';
import '../../domain/entities/goal_entity.dart';
import '../common/account_range_controls.dart';
import '../common/premium_loading.dart';
import 'goal_details_screen.dart';
import 'goal_form_screen.dart';
import 'goals_providers.dart';

class GoalsScreen extends ConsumerWidget {
  const GoalsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(goalsListProvider);
    final currencyLabel = Currency.arabicLabel(
        ref.watch(baseCurrencyProvider).valueOrNull ?? 'SAR');

    return async.when(
      loading: () => const PremiumSkeletonPage(cardCount: 4),
      error: (error, _) => const Center(child: Text('حدث خطأ')),
      data: (goals) {
        final saved =
            goals.fold<double>(0, (sum, goal) => sum + goal.savedAmount);
        final target =
            goals.fold<double>(0, (sum, goal) => sum + goal.targetAmount);
        if (goals.isEmpty) {
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
              const Padding(
                padding: EdgeInsets.fromLTRB(
                  AppSpacing.gutter,
                  AppSpacing.gutter,
                  AppSpacing.gutter,
                  0,
                ),
                child: AccountRangeControls(showRange: false),
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
                count: goals.length,
                saved: saved,
                target: target,
                currencyLabel: currencyLabel,
                onAdd: () => GoalFormScreen.showSheet(context),
              ),
              Padding(
                padding: const EdgeInsets.all(AppSpacing.gutter),
                child: Column(
                  children: [
                    const AccountRangeControls(showRange: false),
                    const SizedBox(height: AppSpacing.s4),
                    for (final goal in goals) ...[
                      _GoalCard(
                        goal: goal,
                        currencyLabel: currencyLabel,
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
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        c.primary.withValues(alpha: 0.22),
                        c.gradB.withValues(alpha: 0.14),
                      ],
                    ),
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    border: Border.all(
                      color: c.primary.withValues(alpha: 0.18),
                    ),
                  ),
                  child: Icon(
                    Icons.savings_outlined,
                    color: c.primary,
                  ),
                ),
                const SizedBox(width: AppSpacing.s3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(goal.name,
                          style: AppTypography.headline(c.textMain)),
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
    final c = context.colors;
    final ratio = target == 0 ? 0 : (saved / target * 100).round();
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        64,
        AppSpacing.gutter,
        AppSpacing.s4,
      ),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            c.cta.withValues(alpha: 0.12),
            c.bg,
          ],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (Navigator.of(context).canPop()) ...[
                BackButton(color: c.textMain),
                const SizedBox(width: AppSpacing.s2),
              ],
              Expanded(
                child: Text(
                  'الأهداف',
                  style: AppTypography.title1(c.textMain)
                      .copyWith(fontWeight: FontWeight.bold),
                ),
              ),
              GestureDetector(
                onTap: onAdd,
                child: Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: c.surfaceCard,
                    shape: BoxShape.circle,
                    border: Border.all(color: c.border),
                  ),
                  child: Icon(Icons.add, color: c.cta, size: 22),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'خزنة صغيرة لكل حلم، ومساهمات واضحة خطوة بخطوة.',
            style: AppTypography.caption(c.textMuted),
          ),
          const SizedBox(height: AppSpacing.s5),
          Container(
            padding: const EdgeInsets.all(AppSpacing.s4),
            decoration: BoxDecoration(
              color: c.surfaceCard,
              borderRadius: BorderRadius.circular(AppRadius.card),
              border: Border.all(color: c.border),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.03),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: c.cta.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(
                        Icons.savings_outlined,
                        color: c.cta,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.s3),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'إجمالي المدخر',
                            style: AppTypography.caption(c.textSecondary),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${Formatters.amount(saved)} $currencyLabel',
                            style: AppTypography.title2(c.textMain)
                                .copyWith(fontWeight: FontWeight.bold, fontFamily: 'Outfit'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.s3),
                  child: Divider(color: c.border, height: 1),
                ),
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '$count',
                            style: AppTypography.bodyStrong(c.textMain)
                                .copyWith(fontWeight: FontWeight.bold, fontFamily: 'Outfit'),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'أهداف نشطة',
                            style: AppTypography.caption(c.textSecondary),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      width: 1,
                      height: 32,
                      color: c.divider,
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '$ratio%',
                            style: AppTypography.bodyStrong(c.textMain)
                                .copyWith(fontWeight: FontWeight.bold, fontFamily: 'Outfit'),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'نسبة التقدم',
                            style: AppTypography.caption(c.textSecondary),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
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
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
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
    );
  }
}
