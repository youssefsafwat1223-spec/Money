import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/formatters.dart';
import '../common/vault_widget.dart';
import '../common/widgets.dart';
import 'dashboard_providers.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(dashboardDataProvider);

    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(dashboardDataProvider),
      child: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ListView(
          children: [
            Padding(
                padding: const EdgeInsets.all(24), child: Text('حدث خطأ: $e'))
          ],
        ),
        data: (data) => ListView(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.gutter, AppSpacing.s4, AppSpacing.gutter, 120),
          children: [
            _greeting(context, data),
            const SizedBox(height: AppSpacing.s5),
            _savedCard(context, data.savedThisMonth),
            const SizedBox(height: AppSpacing.s4),
            if (data.activeGoal != null) _goalCard(context, data),
            if (data.isEmpty)
              _emptyState(context)
            else ...[
              const SizedBox(height: AppSpacing.s5),
              _whereMoneyWent(context, data),
              const SizedBox(height: AppSpacing.s5),
              _recent(context, ref, data),
            ],
          ],
        ),
      ),
    );
  }

  Widget _greeting(BuildContext context, DashboardData data) {
    final c = context.colors;
    final hour = DateTime.now().hour;
    final greeting =
        hour < 12 ? 'صباح الخير' : (hour < 18 ? 'مساء الخير' : 'مساء الخير');
    return Row(
      children: [
        Expanded(
          child:
              Text('$greeting، يوسف', style: AppTypography.title2(c.textMain)),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: c.accent.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                AppLucideIcons.flame,
                size: 16,
                color: c.accent,
              ),
              const SizedBox(width: 5),
              Text(
                '${data.streak.currentStreak} يوم',
                style: AppTypography.caption(c.textMain),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _savedCard(BuildContext context, double saved) {
    final c = context.colors;
    final positive = saved >= 0;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.s5),
      decoration: BoxDecoration(
        gradient: c.primaryGradient,
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('وفّرت هذا الشهر',
              style:
                  AppTypography.subhead(Colors.white.withValues(alpha: 0.85))),
          const SizedBox(height: AppSpacing.s2),
          Text(
            '${positive ? '+' : '−'} ${Formatters.amount(saved.abs())} ريال',
            style: AppTypography.amountHero(Colors.white),
          ),
        ],
      ),
    );
  }

  Widget _goalCard(BuildContext context, DashboardData data) {
    final c = context.colors;
    final goal = data.activeGoal!;
    final progress =
        goal.targetAmount == 0 ? 0.0 : goal.savedAmount / goal.targetAmount;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.s5),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: c.border),
      ),
      child: Column(
        children: [
          Text(goal.name, style: AppTypography.headline(c.textMain)),
          const SizedBox(height: AppSpacing.s4),
          VaultWidget(progress: progress, size: 150),
          const SizedBox(height: AppSpacing.s3),
          Text(
            'وفّرت ${Formatters.integer(goal.savedAmount)} من ${Formatters.integer(goal.targetAmount)} ريال',
            style: AppTypography.subhead(c.textLight),
          ),
        ],
      ),
    );
  }

  Widget _whereMoneyWent(BuildContext context, DashboardData data) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('أين ذهبت أموالك؟', style: AppTypography.title2(c.textMain)),
        const SizedBox(height: AppSpacing.s3),
        for (final slice in data.topCategories) ...[
          _categoryBar(context, slice),
          const SizedBox(height: AppSpacing.s3),
        ],
      ],
    );
  }

  Widget _categoryBar(BuildContext context, CategorySlice slice) {
    final c = context.colors;
    return Row(
      children: [
        CategoryAvatar(category: slice.category, size: 38),
        const SizedBox(width: AppSpacing.s3),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(slice.category.nameAr,
                        style: AppTypography.subhead(c.textMain)),
                  ),
                  Text('${(slice.percent * 100).round()}%',
                      style: AppTypography.caption(c.textLight)),
                ],
              ),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.pill),
                child: LinearProgressIndicator(
                  value: slice.percent,
                  minHeight: 8,
                  backgroundColor: c.surface2,
                  valueColor: AlwaysStoppedAnimation(slice.category.color),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _recent(BuildContext context, WidgetRef ref, DashboardData data) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('آخر العمليات', style: AppTypography.title2(c.textMain)),
        const SizedBox(height: AppSpacing.s2),
        for (final tx in data.recent)
          TransactionRow(
            transaction: tx,
            category: data.catalog.byId(tx.categoryId),
            onTap: () => context.push('/transaction/${tx.id}'),
          ),
      ],
    );
  }

  Widget _emptyState(BuildContext context) {
    final c = context.colors;
    return Container(
      margin: const EdgeInsets.only(top: AppSpacing.s5),
      padding: const EdgeInsets.all(AppSpacing.s6),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: c.border),
      ),
      child: Column(
        children: [
          Icon(
            AppLucideIcons.inbox,
            size: 44,
            color: c.textLight,
          ),
          const SizedBox(height: AppSpacing.s3),
          Text('ما عندك عمليات بعد', style: AppTypography.headline(c.textMain)),
          const SizedBox(height: AppSpacing.s2),
          Text('ألصق أول رسالة بنك ونصنّفها لك تلقائياً.',
              textAlign: TextAlign.center,
              style: AppTypography.callout(c.textLight)),
          const SizedBox(height: AppSpacing.s4),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: FilledButton(
              onPressed: () => context.push('/paste'),
              style: FilledButton.styleFrom(
                backgroundColor: c.primary,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.md)),
              ),
              child: Text('ألصق رسالة',
                  style: AppTypography.bodyStrong(Colors.white)),
            ),
          ),
        ],
      ),
    );
  }
}
