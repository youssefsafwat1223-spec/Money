import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/formatters.dart';
import '../common/charts/spending_charts.dart';
import '../common/motion.dart';
import '../common/premium_loading.dart';
import '../common/widgets.dart';
import '../common/section_hero_header.dart';
import '../dashboard/dashboard_providers.dart' show CategorySlice;
import '../settings/settings_providers.dart';
import 'reports_providers.dart';

class ReportsScreen extends ConsumerWidget {
  const ReportsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(reportsProvider);
    final privacyMode = ref.watch(userSettingsProvider).maybeWhen(
          data: (settings) => settings.privacyModeEnabled,
          orElse: () => false,
        );
    final c = context.colors;
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        body: async.when(
          loading: () => const PremiumSkeletonPage(cardCount: 4),
          error: (e, _) => Center(child: Text('حدث خطأ: $e')),
          data: (bundle) {
            final section = bundle.monthly;
            return Column(
              children: [
                PremiumMotion(
                  child: SectionHeroHeader(
                    title: 'الرؤى',
                    subtitle: 'اقرأ صرفك كاتجاهات يومية وتصنيفات ومتاجر.',
                    metrics: [
                      SectionHeroMetric(
                        value: _money(section.total, privacyMode: privacyMode),
                        label: 'مصروف الشهر',
                      ),
                      SectionHeroMetric(
                        value: _money(section.averageDaily,
                            privacyMode: privacyMode),
                        label: 'متوسط يومي',
                      ),
                      SectionHeroMetric(
                        value: _money(section.highestDaily,
                            privacyMode: privacyMode),
                        label: 'أعلى يوم',
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(AppSpacing.gutter),
                  child: Container(
                    height: 48,
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: c.surface2,
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                    ),
                    child: TabBar(
                      indicatorSize: TabBarIndicatorSize.tab,
                      dividerColor: Colors.transparent,
                      labelColor: Colors.white,
                      unselectedLabelColor: c.textLight,
                      indicator: BoxDecoration(
                        color: c.primary,
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                      ),
                      tabs: const [
                        Tab(text: 'نظرة عامة'),
                        Tab(text: 'الاتجاهات'),
                        Tab(text: 'التفاصيل'),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      _OverviewTab(
                        section: section,
                        privacyMode: privacyMode,
                      ),
                      _TrendsTab(
                        section: section,
                        privacyMode: privacyMode,
                      ),
                      _DetailsTab(
                        section: section,
                        privacyMode: privacyMode,
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

String _money(double amount, {required bool privacyMode}) {
  return privacyMode ? '•••• ر' : '${Formatters.amount(amount)} ر';
}

String _dateLabel(DateTime day) => '${day.day}/${day.month}';

class _OverviewTab extends StatelessWidget {
  const _OverviewTab({
    required this.section,
    required this.privacyMode,
  });

  final ReportSection section;
  final bool privacyMode;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final chartSlices = [
      for (final slice in section.topCategories)
        SpendingChartSlice(
          category: slice.category,
          total: slice.total,
          percent: slice.percent,
        ),
    ];
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.gutter),
      children: [
        PremiumMotion(
          child: _PeriodCard(
            section: section,
            privacyMode: privacyMode,
          ),
        ),
        const SizedBox(height: AppSpacing.s5),
        PremiumMotion(
          delay: const Duration(milliseconds: 70),
          child: _DailySpendCard(
            section: section,
            privacyMode: privacyMode,
          ),
        ),
        if (section.topCategories.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.s5),
          Text('أكثر التصنيفات', style: AppTypography.title2(c.textMain)),
          const SizedBox(height: AppSpacing.s3),
          PremiumMotion(
            delay: const Duration(milliseconds: 120),
            child: CategoryDonutChart(
              slices: chartSlices,
              centerLabel: 'توزيع التصنيفات',
            ),
          ),
          const SizedBox(height: AppSpacing.s4),
          for (final slice in section.topCategories) ...[
            _CategoryBar(slice: slice),
            const SizedBox(height: AppSpacing.s3),
          ],
        ],
      ],
    );
  }
}

class _TrendsTab extends StatelessWidget {
  const _TrendsTab({
    required this.section,
    required this.privacyMode,
  });

  final ReportSection section;
  final bool privacyMode;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final delta = section.deltaPercent;
    final anomaly = section.anomaly;
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.gutter),
      children: [
        if (anomaly != null) ...[
          _InsightCard(
            icon: AppLucideIcons.alertTriangle,
            title: 'صرف غير معتاد',
            body: privacyMode
                ? 'في يوم ${_dateLabel(anomaly.day)} كان الصرف أعلى من نمطك المعتاد. راجعه لو حابب تفهم السبب.'
                : 'في يوم ${_dateLabel(anomaly.day)} صرفت ${_money(anomaly.total, privacyMode: false)}، وهو أعلى من متوسطك اليومي ${anomaly.ratio.toStringAsFixed(1)}×.',
            color: c.danger,
          ),
          const SizedBox(height: AppSpacing.s4),
        ],
        _InsightCard(
          icon: delta == null || delta <= 0
              ? AppLucideIcons.arrowLeftRight
              : AppLucideIcons.arrowLeftRight,
          title: 'مقارنة بنفس الفترة السابقة',
          body: delta == null
              ? 'لسه محتاجين فترة سابقة فيها صرف عشان نعرض الاتجاه بدقة.'
              : delta <= 0
                  ? 'صرفك أقل ${(delta.abs() * 100).round()}% من نفس الفترة السابقة.'
                  : 'صرفك أعلى ${(delta.abs() * 100).round()}% من نفس الفترة السابقة.',
          color: delta == null || delta <= 0 ? c.success : c.danger,
        ),
        const SizedBox(height: AppSpacing.s4),
        _InsightCard(
          icon: AppLucideIcons.shapes,
          title: 'أعلى يوم صرف',
          body:
              'أعلى يوم هذا الشهر وصل إلى ${_money(section.highestDaily, privacyMode: privacyMode)}.',
          color: c.primary,
        ),
        const SizedBox(height: AppSpacing.s4),
        _InsightCard(
          icon: AppLucideIcons.sun,
          title: 'اقتراح سريع',
          body: section.topCategories.isEmpty
              ? 'ابدأ بإضافة عمليات أكثر عشان نطلع اقتراحات أوضح.'
              : 'أكبر صرف عندك على ${section.topCategories.first.category.nameAr}. راقب التصنيف ده أولاً.',
          color: c.accent,
        ),
      ],
    );
  }
}

class _DetailsTab extends StatelessWidget {
  const _DetailsTab({
    required this.section,
    required this.privacyMode,
  });

  final ReportSection section;
  final bool privacyMode;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.gutter),
      children: [
        Text('أكثر المتاجر', style: AppTypography.title2(c.textMain)),
        const SizedBox(height: AppSpacing.s3),
        if (section.topMerchants.isEmpty)
          _InsightCard(
            icon: AppLucideIcons.store,
            title: 'لا توجد متاجر كافية',
            body: 'ستظهر هنا أكثر المتاجر صرفاً بعد إضافة عمليات مؤكدة.',
            color: c.textLight,
          )
        else
          for (final merchant in section.topMerchants)
            Container(
              margin: const EdgeInsets.only(bottom: AppSpacing.s3),
              padding: const EdgeInsets.all(AppSpacing.s4),
              decoration: BoxDecoration(
                color: c.surface,
                borderRadius: BorderRadius.circular(AppRadius.card),
                border: Border.all(color: c.border),
              ),
              child: Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: c.primary.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                    child: Icon(AppLucideIcons.store, color: c.primary),
                  ),
                  const SizedBox(width: AppSpacing.s3),
                  Expanded(
                    child: Text(merchant.name,
                        style: AppTypography.bodyStrong(c.textMain)),
                  ),
                  Text(_money(merchant.total, privacyMode: privacyMode),
                      style: AppTypography.bodyStrong(c.textMain)),
                ],
              ),
            ),
      ],
    );
  }
}

class _PeriodCard extends StatelessWidget {
  const _PeriodCard({
    required this.section,
    required this.privacyMode,
  });

  final ReportSection section;
  final bool privacyMode;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.s5),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('يونيو 2026', style: AppTypography.subhead(c.textLight)),
          const SizedBox(height: AppSpacing.s2),
          Text(_money(section.total, privacyMode: privacyMode),
              style: AppTypography.amountHero(c.textMain)),
          Text('مصروف هذا الشهر', style: AppTypography.caption(c.textLight)),
        ],
      ),
    );
  }
}

class _DailySpendCard extends StatelessWidget {
  const _DailySpendCard({
    required this.section,
    required this.privacyMode,
  });

  final ReportSection section;
  final bool privacyMode;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.s5),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('الصرف اليومي', style: AppTypography.title2(c.textMain)),
          const SizedBox(height: AppSpacing.s4),
          SizedBox(
            height: 180,
            width: double.infinity,
            child: DailySpendBarChart(
              values: section.dailySpend.map((day) => day.total).toList(),
            ),
          ),
          const Divider(height: AppSpacing.s6),
          Row(
            children: [
              Expanded(
                child: _MiniMetric(
                  label: 'المتوسط',
                  value: _money(section.averageDaily, privacyMode: privacyMode),
                ),
              ),
              Expanded(
                child: _MiniMetric(
                  label: 'الأعلى',
                  value: _money(section.highestDaily, privacyMode: privacyMode),
                ),
              ),
              Expanded(
                child: _MiniMetric(
                  label: 'الإجمالي',
                  value: _money(section.total, privacyMode: privacyMode),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MiniMetric extends StatelessWidget {
  const _MiniMetric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      children: [
        Text(label, style: AppTypography.caption(c.textLight)),
        const SizedBox(height: 4),
        Text(value,
            textAlign: TextAlign.center,
            style: AppTypography.caption(c.textMain)
                .copyWith(fontWeight: FontWeight.bold)),
      ],
    );
  }
}

class _CategoryBar extends StatelessWidget {
  const _CategoryBar({required this.slice});

  final CategorySlice slice;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      children: [
        CategoryAvatar(category: slice.category, size: 36),
        const SizedBox(width: AppSpacing.s3),
        Expanded(
          child: Column(
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
}

class _InsightCard extends StatelessWidget {
  const _InsightCard({
    required this.icon,
    required this.title,
    required this.body,
    required this.color,
  });

  final IconData icon;
  final String title;
  final String body;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.s4),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: Icon(icon, color: color),
          ),
          const SizedBox(width: AppSpacing.s3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppTypography.bodyStrong(c.textMain)),
                const SizedBox(height: 4),
                Text(body, style: AppTypography.caption(c.textLight)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
