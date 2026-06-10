import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/formatters.dart';
import '../common/widgets.dart';
import '../dashboard/dashboard_providers.dart' show CategorySlice;
import 'reports_providers.dart';

class ReportsScreen extends ConsumerWidget {
  const ReportsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(reportsProvider);
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('التقارير'),
          bottom: const TabBar(tabs: [Tab(text: 'أسبوعي'), Tab(text: 'شهري')]),
        ),
        body: async.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('حدث خطأ: $e')),
          data: (bundle) => TabBarView(
            children: [
              _SectionView(section: bundle.weekly, periodLabel: 'هذا الأسبوع'),
              _SectionView(section: bundle.monthly, periodLabel: 'هذا الشهر'),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionView extends StatelessWidget {
  const _SectionView({required this.section, required this.periodLabel});

  final ReportSection section;
  final String periodLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final delta = section.deltaPercent;
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.gutter),
      children: [
        Text('إجمالي $periodLabel', style: AppTypography.subhead(c.textLight)),
        const SizedBox(height: AppSpacing.s2),
        Text('${Formatters.amount(section.total)} ريال',
            style: AppTypography.amountHero(c.textMain)),
        if (delta != null) ...[
          const SizedBox(height: AppSpacing.s2),
          _deltaChip(context, delta),
        ],
        const SizedBox(height: AppSpacing.s6),
        if (section.topCategories.isNotEmpty) ...[
          Text('أكثر التصنيفات', style: AppTypography.title2(c.textMain)),
          const SizedBox(height: AppSpacing.s3),
          for (final slice in section.topCategories) ...[
            _categoryBar(context, slice),
            const SizedBox(height: AppSpacing.s3),
          ],
        ],
        if (section.topMerchants.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.s4),
          Text('أكثر المتاجر', style: AppTypography.title2(c.textMain)),
          const SizedBox(height: AppSpacing.s2),
          for (final m in section.topMerchants)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.s2),
              child: Row(
                children: [
                  Expanded(
                      child: Text(m.name,
                          style: AppTypography.body(c.textMain))),
                  Text('${Formatters.amount(m.total)} ريال',
                      style: AppTypography.bodyStrong(c.textMain)),
                ],
              ),
            ),
        ],
        if (section.topCategories.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.s5),
          _insight(context, section),
        ],
      ],
    );
  }

  Widget _deltaChip(BuildContext context, double delta) {
    final c = context.colors;
    final down = delta < 0;
    final color = down ? c.success : c.danger;
    final pct = (delta.abs() * 100).round();
    return Row(
      children: [
        Icon(down ? Icons.arrow_downward : Icons.arrow_upward,
            size: 16, color: color),
        const SizedBox(width: 4),
        Text(
          down ? 'أقل $pct% عن الفترة السابقة' : 'أكثر $pct% عن الفترة السابقة',
          style: AppTypography.subhead(color),
        ),
      ],
    );
  }

  Widget _categoryBar(BuildContext context, CategorySlice slice) {
    final c = context.colors;
    return Row(
      children: [
        CategoryAvatar(category: slice.category, size: 36),
        const SizedBox(width: AppSpacing.s3),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                      child: Text(slice.category.nameAr,
                          style: AppTypography.subhead(c.textMain))),
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

  Widget _insight(BuildContext context, ReportSection section) {
    final c = context.colors;
    final top = section.topCategories.first;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.s4),
      decoration: BoxDecoration(
        color: c.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Row(
        children: [
          Icon(Icons.lightbulb_outline, color: c.primary),
          const SizedBox(width: AppSpacing.s3),
          Expanded(
            child: Text(
              'أكبر صرف على «${top.category.nameAr}». لو قلّلته شوية توفّر أكثر.',
              style: AppTypography.body(c.textMain),
            ),
          ),
        ],
      ),
    );
  }
}