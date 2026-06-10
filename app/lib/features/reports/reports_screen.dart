import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/formatters.dart';
import '../common/widgets.dart';
import '../common/section_hero_header.dart';
import '../dashboard/dashboard_providers.dart' show CategorySlice;
import 'reports_providers.dart';

class ReportsScreen extends ConsumerWidget {
  const ReportsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(reportsProvider);
    final c = context.colors;
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          toolbarHeight: 0,
          backgroundColor: Colors.transparent,
          elevation: 0,
        ),
        body: async.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('حدث خطأ: $e')),
          data: (bundle) {
            final section = bundle.monthly;
            return Column(
              children: [
                SectionHeroHeader(
                  title: 'الرؤى',
                  subtitle: 'اقرأ صرفك كاتجاهات يومية وتصنيفات ومتاجر.',
                  metrics: [
                    SectionHeroMetric(
                      value: '${Formatters.amount(section.total)} ر',
                      label: 'مصروف الشهر',
                    ),
                    SectionHeroMetric(
                      value: '${Formatters.amount(section.averageDaily)} ر',
                      label: 'متوسط يومي',
                    ),
                    SectionHeroMetric(
                      value: '${Formatters.amount(section.highestDaily)} ر',
                      label: 'أعلى يوم',
                    ),
                  ],
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
                      _OverviewTab(section: section),
                      _TrendsTab(section: section),
                      _DetailsTab(section: section),
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

class _OverviewTab extends StatelessWidget {
  const _OverviewTab({required this.section});

  final ReportSection section;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.gutter),
      children: [
        _PeriodCard(section: section),
        const SizedBox(height: AppSpacing.s5),
        _DailySpendCard(section: section),
        if (section.topCategories.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.s5),
          Text('أكثر التصنيفات', style: AppTypography.title2(c.textMain)),
          const SizedBox(height: AppSpacing.s3),
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
  const _TrendsTab({required this.section});

  final ReportSection section;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final delta = section.deltaPercent;
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.gutter),
      children: [
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
              'أعلى يوم هذا الشهر وصل إلى ${Formatters.amount(section.highestDaily)} ريال.',
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
  const _DetailsTab({required this.section});

  final ReportSection section;

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
                  Text('${Formatters.amount(merchant.total)} ريال',
                      style: AppTypography.bodyStrong(c.textMain)),
                ],
              ),
            ),
      ],
    );
  }
}

class _PeriodCard extends StatelessWidget {
  const _PeriodCard({required this.section});

  final ReportSection section;

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
          Text('${Formatters.amount(section.total)} ريال',
              style: AppTypography.amountHero(c.textMain)),
          Text('مصروف هذا الشهر', style: AppTypography.caption(c.textLight)),
        ],
      ),
    );
  }
}

class _DailySpendCard extends StatelessWidget {
  const _DailySpendCard({required this.section});

  final ReportSection section;

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
            child: CustomPaint(
              painter: _DailySpendPainter(
                values: section.dailySpend.map((day) => day.total).toList(),
                lineColor: c.primary,
                gridColor: c.border,
              ),
            ),
          ),
          const Divider(height: AppSpacing.s6),
          Row(
            children: [
              Expanded(
                child: _MiniMetric(
                  label: 'المتوسط',
                  value: '${Formatters.amount(section.averageDaily)} ريال',
                ),
              ),
              Expanded(
                child: _MiniMetric(
                  label: 'الأعلى',
                  value: '${Formatters.amount(section.highestDaily)} ريال',
                ),
              ),
              Expanded(
                child: _MiniMetric(
                  label: 'الإجمالي',
                  value: '${Formatters.amount(section.total)} ريال',
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

class _DailySpendPainter extends CustomPainter {
  const _DailySpendPainter({
    required this.values,
    required this.lineColor,
    required this.gridColor,
  });

  final List<double> values;
  final Color lineColor;
  final Color gridColor;

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (var i = 1; i <= 4; i++) {
      final y = size.height * i / 5;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    if (values.isEmpty) {
      final zeroPaint = Paint()
        ..color = lineColor.withValues(alpha: 0.75)
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(
        Offset(0, size.height * 0.82),
        Offset(size.width, size.height * 0.82),
        zeroPaint,
      );
      return;
    }

    final maxValue = math.max(values.reduce(math.max), 1);
    final step = values.length == 1 ? size.width : size.width / (values.length - 1);
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = i * step;
      final y = size.height - (values[i] / maxValue * size.height * 0.82) - 8;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    final fill = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            lineColor.withValues(alpha: 0.20),
            lineColor.withValues(alpha: 0),
          ],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = lineColor
        ..strokeWidth = 3
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant _DailySpendPainter oldDelegate) =>
      oldDelegate.values != values ||
      oldDelegate.lineColor != lineColor ||
      oldDelegate.gridColor != gridColor;
}
