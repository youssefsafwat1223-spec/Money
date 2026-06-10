import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';

class SectionHeroHeader extends StatelessWidget {
  const SectionHeroHeader({
    super.key,
    required this.title,
    required this.subtitle,
    required this.metrics,
    this.action,
  });

  final String title;
  final String subtitle;
  final List<SectionHeroMetric> metrics;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        AppSpacing.s5,
        AppSpacing.gutter,
        AppSpacing.s6,
      ),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [c.gradA, c.primary, c.gradB],
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
        ),
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(32)),
        boxShadow: [
          BoxShadow(
            color: c.primary.withValues(alpha: 0.20),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: AppTypography.title1(Colors.white)
                  .copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: AppSpacing.s2),
            Text(subtitle, style: AppTypography.callout(Colors.white70)),
            const SizedBox(height: AppSpacing.s5),
            Container(
              padding: const EdgeInsets.all(AppSpacing.s4),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(AppRadius.card),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.20),
                ),
              ),
              child: Row(
                children: [
                  for (var i = 0; i < metrics.length; i++) ...[
                    Expanded(child: _MetricView(metric: metrics[i])),
                    if (i != metrics.length - 1)
                      Container(
                        height: 42,
                        width: 1,
                        color: Colors.white.withValues(alpha: 0.20),
                      ),
                  ],
                ],
              ),
            ),
            if (action != null) ...[
              const SizedBox(height: AppSpacing.s4),
              Center(child: action),
            ],
          ],
        ),
      ),
    );
  }
}

class SectionHeroMetric {
  const SectionHeroMetric({required this.value, required this.label});

  final String value;
  final String label;
}

class _MetricView extends StatelessWidget {
  const _MetricView({required this.metric});

  final SectionHeroMetric metric;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          metric.value,
          textAlign: TextAlign.center,
          style: AppTypography.headline(Colors.white)
              .copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        Text(
          metric.label,
          textAlign: TextAlign.center,
          style: AppTypography.caption(Colors.white70),
        ),
      ],
    );
  }
}
