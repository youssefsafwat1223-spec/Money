import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/utils/async_reload_safe.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/calm_page_header.dart';
import '../../core/theme/widgets/mali_card.dart';
import '../../core/theme/widgets/mali_glass.dart';
import '../common/app_pill_tab_bar.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/currency.dart';
import '../../core/utils/formatters.dart';
import '../../domain/entities/report_models.dart';
import '../../domain/finance/money.dart';
import '../common/charts/spending_charts.dart';
import '../common/motion.dart';
import '../common/premium_loading.dart';
import '../common/widgets.dart';
import '../dashboard/dashboard_providers.dart' show CategorySlice;
import '../settings/settings_providers.dart';
import '../reporting/ui/report_config_sheet.dart';
import '../report_ads/report_ads_providers.dart';
import 'reports_providers.dart';

class ReportsScreen extends ConsumerWidget {
  const ReportsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(reportsProvider);
    final privacyMode = ref.watch(userSettingsProvider).dataOrWhen(
          data: (settings) => settings.privacyModeEnabled,
          orElse: () => false,
        );
    final currencyLabel = Currency.arabicLabel(
        ref.watch(baseCurrencyProvider).valueOrNull ?? 'SAR');

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        body: async.when(
          skipLoadingOnReload: true,
          loading: () => const SkeletonList(rows: 4),
          error: (e, _) => const Center(child: Text('حدث خطأ')),
          data: (bundle) {
            final section = bundle.monthly;
            return SafeArea(
                top: false,
                bottom: false,
                child: NestedScrollView(
                  headerSliverBuilder: (context, innerBoxIsScrolled) {
                    return [
                      SliverToBoxAdapter(
                        child: Column(
                          children: [
                            _ReportsHeader(
                              section: section,
                              currencyLabel: currencyLabel,
                              privacyMode: privacyMode,
                              onReport: () async {
                                final request =
                                    await showReportConfigSheet(context);
                                if (request == null || !context.mounted) return;
                                // R4: route the accepted export through the ad
                                // coordinator (single-flight, fail-open). It
                                // resolves entitlement, may show ONE interstitial,
                                // then generates exactly once via this closure.
                                await ref
                                    .read(reportExportCoordinatorProvider)
                                    .run(() async {
                                  if (!context.mounted) return;
                                  await runReportGeneration(
                                      context, ref, request);
                                });
                              },
                            ),
                          ],
                        ),
                      ),
                      SliverPersistentHeader(
                        pinned: true,
                        delegate: _TabBarDelegate(
                          // iOS 26 style: floating glass capsules, no bar box.
                          child: MeltSlice(
                            height: 64.0,
                            child: Container(
                              height: 64.0,
                              padding: const EdgeInsets.symmetric(
                                horizontal: AppSpacing.gutter,
                              ),
                              alignment: Alignment.center,
                              child: Builder(
                                builder: (context) {
                                  final controller =
                                      DefaultTabController.of(context);
                                  return AnimatedBuilder(
                                    animation: controller,
                                    builder: (context, _) => AppPillTabBar(
                                      tabs: const [
                                        'نظرة عامة',
                                        'الاتجاهات',
                                        'التفاصيل',
                                      ],
                                      selectedIndex: controller.index,
                                      onSelected: controller.animateTo,
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                        ),
                      ),
                    ];
                  },
                  body: TabBarView(
                    children: [
                      _OverviewTab(
                        section: section,
                        weekly: bundle.weekly,
                        currencyLabel: currencyLabel,
                        privacyMode: privacyMode,
                      ),
                      _TrendsTab(
                        section: section,
                        currencyLabel: currencyLabel,
                        privacyMode: privacyMode,
                      ),
                      _DetailsTab(
                        section: section,
                        currencyLabel: currencyLabel,
                        privacyMode: privacyMode,
                      ),
                    ],
                  ),
                ));
          },
        ),
      ),
    );
  }
}

String _money(
  Money amount, {
  required String currencyLabel,
  required bool privacyMode,
}) {
  return privacyMode
      ? '•••• $currencyLabel'
      : '${Formatters.amount(amount.toDouble())} $currencyLabel';
}

String _dateLabel(DateTime day) => '${day.day}/${day.month}';

class _OverviewTab extends StatelessWidget {
  const _OverviewTab({
    required this.section,
    required this.weekly,
    required this.currencyLabel,
    required this.privacyMode,
  });

  final ReportSection section;
  final ReportSection weekly;
  final String currencyLabel;
  final bool privacyMode;

  @override
  Widget build(BuildContext context) {
    return MeltTail(
        startAt: 64,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            AppSpacing.s4,
            AppSpacing.gutter,
            AppSpacing.gutter,
          ),
          children: [
            if (!weekly.total.isZero && !weekly.total.isNegative) ...[
              PremiumMotion(
                child: _WeeklyInsightCard(
                  weekly: weekly,
                  currencyLabel: currencyLabel,
                ),
              ),
              const SizedBox(height: AppSpacing.s4),
            ],
            PremiumMotion(
              child: _PeriodCard(
                section: section,
                currencyLabel: currencyLabel,
                privacyMode: privacyMode,
              ),
            ),
            const SizedBox(height: AppSpacing.s4),
            PremiumMotion(
              delay: const Duration(milliseconds: 70),
              child: _WeeklySpendCard(
                section: weekly,
                currencyLabel: currencyLabel,
                privacyMode: privacyMode,
              ),
            ),
            if (section.topCategories.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.s4),
              PremiumMotion(
                delay: const Duration(milliseconds: 120),
                child: _CategoryDistributionCard(
                  section: section,
                  currencyLabel: currencyLabel,
                  privacyMode: privacyMode,
                ),
              ),
            ],
            if (section.topMerchants.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.s4),
              PremiumMotion(
                delay: const Duration(milliseconds: 160),
                child: _MerchantRankingCard(
                  section: section,
                  currencyLabel: currencyLabel,
                  privacyMode: privacyMode,
                ),
              ),
            ],
          ],
        ));
  }
}

class _TrendsTab extends StatelessWidget {
  const _TrendsTab({
    required this.section,
    required this.currencyLabel,
    required this.privacyMode,
  });

  final ReportSection section;
  final String currencyLabel;
  final bool privacyMode;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final delta = section.deltaPercent;
    final anomaly = section.anomaly;
    return MeltTail(
        startAt: 64,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            AppSpacing.s4,
            AppSpacing.gutter,
            AppSpacing.gutter,
          ),
          children: [
            if (anomaly != null) ...[
              _InsightCard(
                icon: AppLucideIcons.alertTriangle,
                title: 'صرف غير معتاد',
                body: privacyMode
                    ? 'في يوم ${_dateLabel(anomaly.day)} كان الصرف أعلى من نمطك المعتاد. راجعه لو حابب تفهم السبب.'
                    : 'في يوم ${_dateLabel(anomaly.day)} صرفت ${_money(anomaly.total, currencyLabel: currencyLabel, privacyMode: false)}، وهو أعلى من متوسطك اليومي ${anomaly.ratio.toStringAsFixed(1)}×.',
                color: c.danger,
              ),
              const SizedBox(height: AppSpacing.s4),
            ],
            _InsightCard(
              icon: delta == null || delta <= 0
                  ? AppLucideIcons.trendingDown
                  : AppLucideIcons.trendingUp,
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
                  'أعلى يوم في الفترة وصل إلى ${_money(section.highestDaily, currencyLabel: currencyLabel, privacyMode: privacyMode)}.',
              color: c.primary,
            ),
            const SizedBox(height: AppSpacing.s4),
            _InsightCard(
              icon: AppLucideIcons.sun,
              title: 'اقتراح سريع',
              body: section.topCategories.isEmpty
                  ? 'ابدأ بإضافة عمليات أكثر عشان نطلع اقتراحات أوضح.'
                  : 'أكبر صرف عندك على ${section.topCategories.first.category.nameAr}. راقب التصنيف ده أولاً.',
              color: c.cta,
            ),
          ],
        ));
  }
}

class _DetailsTab extends StatelessWidget {
  const _DetailsTab({
    required this.section,
    required this.currencyLabel,
    required this.privacyMode,
  });

  final ReportSection section;
  final String currencyLabel;
  final bool privacyMode;

  @override
  Widget build(BuildContext context) {
    return MeltTail(
        startAt: 64,
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.gutter),
          children: [
            _MerchantRankingCard(
              section: section,
              currencyLabel: currencyLabel,
              privacyMode: privacyMode,
            ),
            const SizedBox(height: AppSpacing.s4),
            _CategoryDistributionCard(
              section: section,
              currencyLabel: currencyLabel,
              privacyMode: privacyMode,
            ),
          ],
        ));
  }
}

class _PeriodCard extends StatelessWidget {
  const _PeriodCard({
    required this.section,
    required this.currencyLabel,
    required this.privacyMode,
  });

  final ReportSection section;
  final String currencyLabel;
  final bool privacyMode;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return MaliCard(
      style: MaliSurfaceStyle.floating,
      padding: const EdgeInsets.all(AppSpacing.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('الفترة المختارة', style: AppTypography.subhead(c.textLight)),
          const SizedBox(height: AppSpacing.s2),
          Text(
              _money(section.total,
                  currencyLabel: currencyLabel, privacyMode: privacyMode),
              style: AppTypography.amountHero(c.textMain)),
          Text('مصروف الفترة المختارة',
              style: AppTypography.caption(c.textLight)),
        ],
      ),
    );
  }
}

class _WeeklySpendCard extends StatelessWidget {
  const _WeeklySpendCard({
    required this.section,
    required this.currencyLabel,
    required this.privacyMode,
  });

  final ReportSection section;
  final String currencyLabel;
  final bool privacyMode;

  @override
  Widget build(BuildContext context) {
    return MaliCard(
      style: MaliSurfaceStyle.floating,
      padding: const EdgeInsets.all(AppSpacing.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _VisualSectionTitle(
            icon: AppLucideIcons.barChart3,
            title: 'استهلاك الأسبوع الحالي',
            subtitle: 'آخر 7 أيام',
          ),
          const SizedBox(height: AppSpacing.s4),
          WeeklyCapsuleBarChart(
            days: section.dailySpend,
            currencyLabel: currencyLabel,
            privacyMode: privacyMode,
            height: 186,
            barWidth: 24,
            maxBarHeight: 78,
          ),
          const Divider(height: AppSpacing.s5),
          Row(
            children: [
              Expanded(
                child: _MiniMetric(
                  label: 'المتوسط',
                  value: _money(section.averageDaily,
                      currencyLabel: currencyLabel, privacyMode: privacyMode),
                ),
              ),
              Expanded(
                child: _MiniMetric(
                  label: 'الأعلى',
                  value: _money(section.highestDaily,
                      currencyLabel: currencyLabel, privacyMode: privacyMode),
                ),
              ),
              Expanded(
                child: _MiniMetric(
                  label: 'الإجمالي',
                  value: _money(section.total,
                      currencyLabel: currencyLabel, privacyMode: privacyMode),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CategoryDistributionCard extends StatelessWidget {
  const _CategoryDistributionCard({
    required this.section,
    required this.currencyLabel,
    required this.privacyMode,
  });

  final ReportSection section;
  final String currencyLabel;
  final bool privacyMode;

  @override
  Widget build(BuildContext context) {
    final slices = [
      for (final slice in section.topCategories)
        SpendingChartSlice(
          category: slice.category,
          total: slice.total.toDouble(),
          percent: slice.percent,
          count: slice.count,
        ),
    ];
    return MaliCard(
      style: MaliSurfaceStyle.floating,
      padding: const EdgeInsets.all(AppSpacing.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _VisualSectionTitle(
            icon: AppLucideIcons.pieChart,
            title: 'استهلاكك بالتصنيفات',
            subtitle: _money(section.total,
                currencyLabel: currencyLabel, privacyMode: privacyMode),
          ),
          const SizedBox(height: AppSpacing.s3),
          CategoryDonutChart(
            slices: slices.take(6).toList(),
            currencyLabel: currencyLabel,
            centerLabel: _money(section.total,
                currencyLabel: currencyLabel, privacyMode: privacyMode),
            compactCenter: true,
            framed: false,
            showLegend: false,
            height: 142,
          ),
          const SizedBox(height: AppSpacing.s3),
          Wrap(
            spacing: AppSpacing.s3,
            runSpacing: AppSpacing.s3,
            children: [
              for (final slice in section.topCategories.take(8))
                SizedBox(
                  width: MediaQuery.sizeOf(context).width >= 430
                      ? (MediaQuery.sizeOf(context).width -
                              AppSpacing.gutter * 2 -
                              AppSpacing.s3 * 3 -
                              AppSpacing.s4 * 2) /
                          2
                      : double.infinity,
                  child: _CategoryLegendTile(
                    slice: slice,
                    currencyLabel: currencyLabel,
                    privacyMode: privacyMode,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MerchantRankingCard extends StatelessWidget {
  const _MerchantRankingCard({
    required this.section,
    required this.currencyLabel,
    required this.privacyMode,
  });

  final ReportSection section;
  final String currencyLabel;
  final bool privacyMode;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final maxTotal = section.topMerchants.fold<double>(
      1,
      (max, merchant) {
        final chartValue = merchant.total.toDouble();
        return chartValue > max ? chartValue : max;
      },
    );
    return MaliCard(
      style: MaliSurfaceStyle.floating,
      padding: const EdgeInsets.all(AppSpacing.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _VisualSectionTitle(
            icon: AppLucideIcons.store,
            title: 'مصروفاتك في المتاجر',
            subtitle: 'أكبر أماكن الصرف في الفترة',
          ),
          const SizedBox(height: AppSpacing.s3),
          if (section.topMerchants.isEmpty)
            Text('ستظهر هنا أكثر المتاجر صرفاً بعد إضافة عمليات مؤكدة.',
                style: AppTypography.caption(c.textLight))
          else
            for (final merchant in section.topMerchants.take(8)) ...[
              _MerchantBarRow(
                merchant: merchant,
                maxTotal: maxTotal,
                currencyLabel: currencyLabel,
                privacyMode: privacyMode,
              ),
              if (merchant != section.topMerchants.take(8).last)
                const SizedBox(height: AppSpacing.s3),
            ],
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

class _VisualSectionTitle extends StatelessWidget {
  const _VisualSectionTitle({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      children: [
        Icon(icon, color: c.success, size: 22),
        const SizedBox(width: AppSpacing.s2),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: AppTypography.cardTitle(c.textMain)),
              const SizedBox(height: 2),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.caption(c.textLight),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CategoryLegendTile extends StatelessWidget {
  const _CategoryLegendTile({
    required this.slice,
    required this.currencyLabel,
    required this.privacyMode,
  });

  final CategorySlice slice;
  final String currencyLabel;
  final bool privacyMode;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      children: [
        AppAvatar.category(category: slice.category, size: AppSpacing.avatarSm),
        const SizedBox(width: AppSpacing.s2),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '%${(slice.percent * 100).round()} ${slice.category.nameAr}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.subhead(c.textMain),
              ),
              Text(
                '${_money(slice.total, currencyLabel: currencyLabel, privacyMode: privacyMode)}'
                '${slice.count > 0 ? ' · ${slice.count} عملية' : ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.caption(c.textLight),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MerchantBarRow extends StatelessWidget {
  const _MerchantBarRow({
    required this.merchant,
    required this.maxTotal,
    required this.currencyLabel,
    required this.privacyMode,
  });

  final MerchantSpend merchant;
  final double maxTotal;
  final String currencyLabel;
  final bool privacyMode;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final ratio = maxTotal <= 0
        ? 0.0
        : (merchant.total.toDouble() / maxTotal).clamp(0.0, 1.0);
    return Row(
      children: [
        AppAvatar.brand(name: merchant.name),
        const SizedBox(width: AppSpacing.s3),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      merchant.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.subhead(c.textMain),
                    ),
                  ),
                  Text(
                    _money(merchant.total,
                        currencyLabel: currencyLabel, privacyMode: privacyMode),
                    style: AppTypography.caption(c.textSecondary)
                        .copyWith(fontWeight: FontWeight.w700),
                  ),
                ],
              ),
              const SizedBox(height: 7),
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.pill),
                child: LinearProgressIndicator(
                  value: ratio,
                  minHeight: 6,
                  backgroundColor: c.surface2,
                  valueColor: AlwaysStoppedAnimation(c.primary),
                ),
              ),
              if (merchant.count > 0) ...[
                const SizedBox(height: 3),
                Text('${merchant.count} عملية',
                    style: AppTypography.caption(c.textLight)),
              ],
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
    return MaliCard(
      style: MaliSurfaceStyle.floating,
      padding: const EdgeInsets.all(AppSpacing.s4),
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

/// Raised-disc action button (matches the transactions "+" style) that opens
/// the PDF report flow from the reports header.
class _ReportButton extends StatelessWidget {
  const _ReportButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MaliGlass(
      variant: MaliGlassVariant.headerAction,
      onTap: onTap,
      child: const SizedBox(
        width: 44,
        height: 44,
        child: Center(
          child: Icon(AppLucideIcons.fileText, color: Colors.white, size: 22),
        ),
      ),
    );
  }
}

class _ReportsHeader extends StatelessWidget {
  const _ReportsHeader({
    required this.section,
    required this.currencyLabel,
    required this.privacyMode,
    required this.onReport,
  });

  final ReportSection section;
  final String currencyLabel;
  final bool privacyMode;
  final VoidCallback onReport;

  @override
  Widget build(BuildContext context) {
    return CalmPageHeader(
      // شرائح متعددة: الأزرق ميمتدّش تحت (هيغطّي المحتوى) — الذوبان جوّه.
      meltOverflow: 0,
      title: 'الرؤى والتقارير',
      subtitle: 'اقرأ صرفك كاتجاهات يومية وتصنيفات ومتاجر.',
      leading: Navigator.of(context).canPop()
          ? const BackButton(color: Colors.white)
          : null,
      trailing: _ReportButton(onTap: onReport),
      amount:
          privacyMode ? '••••' : Formatters.amount(section.total.toDouble()),
      currency: privacyMode ? '' : currencyLabel,
      metrics: [
        CalmMetric(
          label: 'متوسط يومي',
          value: _money(section.averageDaily,
              currencyLabel: currencyLabel, privacyMode: privacyMode),
        ),
        CalmMetric(
          label: 'أعلى يوم',
          value: _money(section.highestDaily,
              currencyLabel: currencyLabel, privacyMode: privacyMode),
        ),
      ],
    );
  }
}

class _WeeklyInsightCard extends StatelessWidget {
  const _WeeklyInsightCard({
    required this.weekly,
    required this.currencyLabel,
  });

  final ReportSection weekly;
  final String currencyLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final delta = weekly.deltaPercent;
    final deltaSign = (delta ?? 0) < 0 ? '↓' : '↑';
    final deltaColor = (delta ?? 0) < 0 ? c.success : c.danger;
    final deltaText = delta == null
        ? null
        : '$deltaSign ${(delta.abs() * 100).toStringAsFixed(0)}% مقارنة بالأسبوع الماضي';

    final bestDay = weekly.bestSavingsDay;
    final topCat = weekly.topCategory;
    final topMerchant = weekly.topMerchant;

    final insights = <(IconData, String, Color)>[
      if (deltaText != null)
        (
          (delta ?? 0) < 0
              ? AppLucideIcons.trendingDown
              : AppLucideIcons.trendingUp,
          deltaText,
          deltaColor,
        ),
      if (topCat != null)
        (
          AppLucideIcons.shapes,
          'أكثر فئة صرفًا: ${topCat.category.nameAr}',
          c.cta,
        ),
      if (bestDay != null)
        (
          AppLucideIcons.star,
          'أفضل يوم توفيرًا: ${bestDay.day.day}/${bestDay.day.month} '
              '(${Formatters.amount(bestDay.total.toDouble())} $currencyLabel)',
          c.success,
        ),
      if (topMerchant != null)
        (
          AppLucideIcons.store,
          'أكثر متجر صرفًا: ${topMerchant.name} '
              '(${Formatters.amount(topMerchant.total.toDouble())} $currencyLabel)',
          c.textMuted,
        ),
    ];

    if (insights.isEmpty) return const SizedBox.shrink();

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('ملخص الأسبوع', style: AppTypography.bodyStrong(c.textMain)),
          const SizedBox(height: AppSpacing.s3),
          ...insights.map(
            (item) => Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.s2),
              child: Row(
                children: [
                  Icon(item.$1, size: 15, color: item.$3),
                  const SizedBox(width: AppSpacing.s2),
                  Expanded(
                    child: Text(
                      item.$2,
                      style: AppTypography.caption(c.textMain),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TabBarDelegate extends SliverPersistentHeaderDelegate {
  _TabBarDelegate({required this.child});
  final Widget child;

  @override
  double get minExtent => 64.0;
  @override
  double get maxExtent => 64.0;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    return child;
  }

  @override
  bool shouldRebuild(covariant _TabBarDelegate oldDelegate) {
    return oldDelegate.child != child;
  }
}
