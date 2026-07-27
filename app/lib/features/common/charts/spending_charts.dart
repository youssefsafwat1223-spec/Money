import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../domain/entities/report_models.dart';
import '../category_catalog.dart';
import '../widgets.dart';

class SpendingChartSlice {
  const SpendingChartSlice({
    required this.category,
    required this.total,
    required this.percent,
    this.count = 0,
  });

  final CategoryView category;
  final double total;
  final double percent;
  final int count;
}

class CategoryDonutChart extends StatelessWidget {
  const CategoryDonutChart({
    super.key,
    required this.slices,
    this.height = 210,
    this.centerLabel = 'التصنيفات',
    this.currencyLabel = '',
    this.compactCenter = false,
    this.framed = true,
    this.showLegend = true,
  });

  final List<SpendingChartSlice> slices;
  final double height;
  final String centerLabel;
  final String currencyLabel;
  final bool compactCenter;
  final bool framed;
  final bool showLegend;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (slices.isEmpty) {
      return _EmptyChartCard(
        title: centerLabel,
        body: 'أضف عمليات مؤكدة عشان يظهر توزيع التصنيفات هنا.',
      );
    }

    final content = Padding(
      padding: framed ? const EdgeInsets.all(AppSpacing.s4) : EdgeInsets.zero,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 260;
          final chartSize = math.min(
            height,
            compact ? constraints.maxWidth.clamp(96.0, 160.0) : height * 0.72,
          );
          final chart = SizedBox(
            height: chartSize,
            width: chartSize,
            child: _Donut(
              slices: slices,
              size: chartSize,
              centerLabelColor: c.textPrimary,
              centerCaptionColor: c.textMuted,
              centerLabel: centerLabel,
              compactCenter: compactCenter,
            ),
          );
          final legend = SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            child: Column(
              children: [
                for (final slice in slices)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.s3),
                    child: _LegendRow(
                      slice: slice,
                      currencyLabel: currencyLabel,
                    ),
                  ),
              ],
            ),
          );

          if (compact) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                chart,
                if (showLegend) ...[
                  const SizedBox(height: AppSpacing.s3),
                  legend,
                ],
              ],
            );
          }

          if (!showLegend) return Center(child: chart);

          return Row(
            children: [
              chart,
              const SizedBox(width: AppSpacing.s3),
              Expanded(child: legend),
            ],
          );
        },
      ),
    );
    if (!framed) return content;
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: c.border),
      ),
      child: content,
    );
  }
}

class WeeklyCapsuleBarChart extends StatelessWidget {
  const WeeklyCapsuleBarChart({
    super.key,
    required this.days,
    required this.currencyLabel,
    required this.privacyMode,
    this.height = 250,
    this.showCurrencyLabel = false,
    this.barWidth = 28,
    this.maxBarHeight = 90,
  });

  final List<DailySpend> days;
  final String currencyLabel;
  final bool privacyMode;
  final double height;
  final bool showCurrencyLabel;
  final double barWidth;
  final double maxBarHeight;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final visibleDays = _lastSevenDays(days);
    final maxValue = visibleDays.fold<double>(
      1,
      (max, day) => day.total > max ? day.total : max,
    );
    final palette = [
      c.primary,
      c.accent,
      c.success,
      c.cta,
      c.danger,
      c.warning,
      c.textSecondary,
    ];
    return SizedBox(
      height: height,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < visibleDays.length; i++) ...[
            Expanded(
              child: _CapsuleBar(
                day: visibleDays[i],
                maxValue: maxValue,
                color: palette[i % palette.length],
                currencyLabel: currencyLabel,
                privacyMode: privacyMode,
                showCurrencyLabel: showCurrencyLabel,
                barWidth: barWidth,
                maxBarHeight: maxBarHeight,
              ),
            ),
            if (i != visibleDays.length - 1) const SizedBox(width: 7),
          ],
        ],
      ),
    );
  }

  List<DailySpend> _lastSevenDays(List<DailySpend> source) {
    final sorted = [...source]..sort((a, b) => a.day.compareTo(b.day));
    if (sorted.length >= 7) return sorted.sublist(sorted.length - 7);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final existing = {
      for (final day in sorted)
        DateTime(day.day.year, day.day.month, day.day.day): day,
    };
    return [
      for (var i = 6; i >= 0; i--)
        existing[today.subtract(Duration(days: i))] ??
            DailySpend(day: today.subtract(Duration(days: i)), total: 0),
    ];
  }
}

class _CapsuleBar extends StatelessWidget {
  const _CapsuleBar({
    required this.day,
    required this.maxValue,
    required this.color,
    required this.currencyLabel,
    required this.privacyMode,
    required this.showCurrencyLabel,
    required this.barWidth,
    required this.maxBarHeight,
  });

  final DailySpend day;
  final double maxValue;
  final Color color;
  final String currencyLabel;
  final bool privacyMode;
  final bool showCurrencyLabel;
  final double barWidth;
  final double maxBarHeight;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final ratio = maxValue <= 0 ? 0.0 : (day.total / maxValue).clamp(0.0, 1.0);
    final barHeight = 24 + ratio * maxBarHeight;
    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        SizedBox(
          height: showCurrencyLabel ? 46 : 32,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Column(
              children: [
                Text(
                  privacyMode ? '••••' : Formatters.amount(day.total),
                  textAlign: TextAlign.center,
                  style: AppTypography.caption(c.textSecondary)
                      .copyWith(fontWeight: FontWeight.w700),
                ),
                if (showCurrencyLabel)
                  Text(
                    currencyLabel,
                    style: AppTypography.caption(c.textMuted)
                        .copyWith(fontSize: 10),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.s1),
        AnimatedContainer(
          duration: const Duration(milliseconds: 280),
          width: barWidth,
          height: barHeight,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(AppRadius.pill),
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: 0.20),
                blurRadius: 14,
                offset: const Offset(0, 8),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.s1),
        Text(
          _weekdayLabel(day.day),
          style: AppTypography.caption(c.textMuted).copyWith(fontSize: 10),
          maxLines: 1,
        ),
      ],
    );
  }

  String _weekdayLabel(DateTime day) {
    const labels = [
      'الإثنين',
      'الثلاثاء',
      'الأربعاء',
      'الخميس',
      'الجمعة',
      'السبت',
      'الأحد',
    ];
    return labels[day.weekday - 1];
  }
}

class _Donut extends StatelessWidget {
  const _Donut({
    required this.slices,
    required this.size,
    required this.centerLabelColor,
    required this.centerCaptionColor,
    required this.centerLabel,
    required this.compactCenter,
  });

  final List<SpendingChartSlice> slices;
  final double size;
  final Color centerLabelColor;
  final Color centerCaptionColor;
  final String centerLabel;
  final bool compactCenter;

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        PieChart(
          PieChartData(
            centerSpaceRadius: size * 0.26,
            sectionsSpace: 3,
            startDegreeOffset: -90,
            sections: [
              for (final slice in slices)
                PieChartSectionData(
                  value: math.max(slice.total, 0.01),
                  color: slice.category.color,
                  radius: size * 0.18,
                  showTitle: false,
                ),
            ],
          ),
        ),
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: size * 0.52),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                compactCenter
                    ? centerLabel
                    : '${(slices.first.percent * 100).round()}%',
                style: AppTypography.bodyStrong(centerLabelColor).copyWith(
                  fontSize: compactCenter ? 12 : null,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                compactCenter ? 'إجمالي' : slices.first.category.nameAr,
                style: AppTypography.caption(centerCaptionColor),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class DailySpendBarChart extends StatelessWidget {
  const DailySpendBarChart({
    super.key,
    required this.values,
    this.height = 180,
    this.selectedIndex,
    this.onBarTap,
  });

  final List<double> values;
  final double height;
  final int? selectedIndex;
  final ValueChanged<int>? onBarTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final safeValues = values.isEmpty ? const [0.0] : values;
    final maxValue = math.max(safeValues.reduce(math.max), 1);

    return SizedBox(
      height: height,
      width: double.infinity,
      child: BarChart(
        BarChartData(
          maxY: maxValue * 1.2,
          alignment: BarChartAlignment.spaceBetween,
          barTouchData: BarTouchData(
            enabled: onBarTap != null,
            touchCallback: (event, response) {
              if (!event.isInterestedForInteractions) return;
              final index = response?.spot?.touchedBarGroupIndex;
              if (index == null || index < 0 || index >= safeValues.length) {
                return;
              }
              onBarTap?.call(index);
            },
          ),
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            getDrawingHorizontalLine: (_) => FlLine(
              color: c.border.withValues(alpha: 0.7),
              strokeWidth: 1,
            ),
          ),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            topTitles:
                const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            leftTitles:
                const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles:
                const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 22,
                interval: math.max((safeValues.length / 6).floorToDouble(), 1),
                getTitlesWidget: (value, meta) {
                  final index = value.toInt();
                  if (index < 0 || index >= safeValues.length) {
                    return const SizedBox.shrink();
                  }
                  return Text(
                    '${index + 1}',
                    style: AppTypography.caption(c.textMuted)
                        .copyWith(fontSize: 10),
                  );
                },
              ),
            ),
          ),
          barGroups: [
            for (var i = 0; i < safeValues.length; i++)
              BarChartGroupData(
                x: i,
                barRods: [
                  BarChartRodData(
                    toY: safeValues[i],
                    width: safeValues.length > 18 ? 7 : 11,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                    color: selectedIndex == i ? c.accent : c.primary,
                    backDrawRodData: BackgroundBarChartRodData(
                      show: false,
                      toY: maxValue * 1.2,
                      color: c.surface2,
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class CompactSparkline extends StatelessWidget {
  const CompactSparkline({
    super.key,
    required this.values,
    this.color,
    this.height = 42,
  });

  final List<double> values;
  final Color? color;
  final double height;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final lineColor = color ?? c.accent;
    final safeValues = values.isEmpty ? const [0.0, 0.0] : values;
    final maxValue = math.max(safeValues.reduce(math.max), 1);

    return SizedBox(
      height: height,
      child: LineChart(
        LineChartData(
          minY: 0,
          maxY: maxValue * 1.15,
          gridData: const FlGridData(show: false),
          borderData: FlBorderData(show: false),
          titlesData: const FlTitlesData(show: false),
          lineTouchData: const LineTouchData(enabled: false),
          lineBarsData: [
            LineChartBarData(
              spots: [
                for (var i = 0; i < safeValues.length; i++)
                  FlSpot(i.toDouble(), safeValues[i]),
              ],
              isCurved: true,
              barWidth: 3,
              dotData: const FlDotData(show: false),
              color: lineColor,
              belowBarData: BarAreaData(
                show: true,
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    lineColor.withValues(alpha: 0.28),
                    lineColor.withValues(alpha: 0),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LegendRow extends StatelessWidget {
  const _LegendRow({required this.slice, required this.currencyLabel});

  final SpendingChartSlice slice;
  final String currencyLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      children: [
        CategoryAvatar(category: slice.category, size: 34),
        const SizedBox(width: AppSpacing.s2),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(slice.category.nameAr,
                  style: AppTypography.caption(c.textPrimary)),
              const SizedBox(height: 2),
              Text(
                [
                  Formatters.amount(slice.total),
                  if (currencyLabel.isNotEmpty) currencyLabel,
                  if (slice.count > 0) '· ${slice.count} عملية',
                ].join(' '),
                style: AppTypography.caption(c.textMuted),
              ),
            ],
          ),
        ),
        Text(
          '${(slice.percent * 100).round()}%',
          style: AppTypography.bodyStrong(slice.category.color),
        ),
      ],
    );
  }
}

class _EmptyChartCard extends StatelessWidget {
  const _EmptyChartCard({required this.title, required this.body});

  final String title;
  final String body;

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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: AppTypography.bodyStrong(c.textPrimary)),
          const SizedBox(height: AppSpacing.s2),
          Text(body, style: AppTypography.caption(c.textMuted)),
        ],
      ),
    );
  }
}
