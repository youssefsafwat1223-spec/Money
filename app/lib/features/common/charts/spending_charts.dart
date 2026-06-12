import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../category_catalog.dart';
import '../widgets.dart';

class SpendingChartSlice {
  const SpendingChartSlice({
    required this.category,
    required this.total,
    required this.percent,
  });

  final CategoryView category;
  final double total;
  final double percent;
}

class CategoryDonutChart extends StatelessWidget {
  const CategoryDonutChart({
    super.key,
    required this.slices,
    this.height = 210,
    this.centerLabel = 'التصنيفات',
  });

  final List<SpendingChartSlice> slices;
  final double height;
  final String centerLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (slices.isEmpty) {
      return _EmptyChartCard(
        title: centerLabel,
        body: 'أضف عمليات مؤكدة عشان يظهر توزيع التصنيفات هنا.',
      );
    }

    return Container(
      padding: const EdgeInsets.all(AppSpacing.s4),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          SizedBox(
            height: height,
            width: height * 0.72,
            child: Stack(
              alignment: Alignment.center,
              children: [
                PieChart(
                  PieChartData(
                    centerSpaceRadius: height * 0.19,
                    sectionsSpace: 3,
                    startDegreeOffset: -90,
                    sections: [
                      for (final slice in slices)
                        PieChartSectionData(
                          value: math.max(slice.total, 0.01),
                          color: slice.category.color,
                          radius: height * 0.13,
                          showTitle: false,
                        ),
                    ],
                  ),
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${(slices.first.percent * 100).round()}%',
                      style: AppTypography.bodyStrong(c.textMain),
                    ),
                    Text(
                      slices.first.category.nameAr,
                      style: AppTypography.caption(c.textLight),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.s3),
          Expanded(
            child: Column(
              children: [
                for (final slice in slices)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.s3),
                    child: _LegendRow(slice: slice),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class DailySpendBarChart extends StatelessWidget {
  const DailySpendBarChart({
    super.key,
    required this.values,
    this.height = 180,
  });

  final List<double> values;
  final double height;

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
                    style: AppTypography.caption(c.textLight)
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
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [c.primary, c.accent],
                    ),
                    backDrawRodData: BackgroundBarChartRodData(
                      show: true,
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
  const _LegendRow({required this.slice});

  final SpendingChartSlice slice;

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
                  style: AppTypography.caption(c.textMain)),
              const SizedBox(height: 2),
              Text(
                '${Formatters.amount(slice.total)} ريال',
                style: AppTypography.caption(c.textLight),
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
          Text(title, style: AppTypography.bodyStrong(c.textMain)),
          const SizedBox(height: AppSpacing.s2),
          Text(body, style: AppTypography.caption(c.textLight)),
        ],
      ),
    );
  }
}
