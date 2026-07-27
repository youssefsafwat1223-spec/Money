import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';

class SectionHeroHeader extends StatelessWidget {
  const SectionHeroHeader({
    super.key,
    required this.title,
    required this.subtitle,
    this.metrics = const [],
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
        color: c.bg,
      ),
      child: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (Navigator.of(context).canPop()) ...[
                  BackButton(color: c.textPrimary),
                  const SizedBox(width: AppSpacing.s2),
                ],
                Expanded(
                  child: Text(
                    title,
                    style: AppTypography.title2(c.textPrimary)
                        .copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.s2),
            Text(subtitle, style: AppTypography.caption(c.textMuted)),
            if (metrics.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.s5),
              Container(
                padding: const EdgeInsets.all(AppSpacing.s4),
                decoration: BoxDecoration(
                  color: c.surfaceCard,
                  borderRadius: BorderRadius.circular(AppRadius.card),
                  border: Border.all(
                    color: c.border,
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
                          color: c.divider,
                        ),
                    ],
                  ],
                ),
              ),
            ],
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
    final c = context.colors;
    return Column(
      children: [
        Text(
          metric.value,
          textAlign: TextAlign.center,
          style: AppTypography.headline(c.textPrimary)
              .copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        Text(
          metric.label,
          textAlign: TextAlign.center,
          style: AppTypography.caption(c.textSecondary),
        ),
      ],
    );
  }
}
