import 'package:flutter/material.dart';

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
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        AppSpacing.s5,
        AppSpacing.gutter,
        AppSpacing.s6,
      ),
      decoration: const BoxDecoration(
        // تدرّج بهاما الأزرق الموحّد (مطابق للـ dashboard) — يشتغل في الفاتح والداكن.
        gradient: LinearGradient(
          colors: [
            Color(0xFF046E9B),
            Color(0xFF034E73),
            Color(0xFF012438),
          ],
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
        ),
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(34)),
        boxShadow: [
          BoxShadow(
            color: Color(0x40034F73),
            blurRadius: 26,
            offset: Offset(0, 14),
          ),
        ],
      ),
      child: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (Navigator.of(context).canPop()) ...[
                  const BackButton(color: Colors.white),
                  const SizedBox(width: AppSpacing.s2),
                ],
                Expanded(
                  child: Text(
                    title,
                    style: AppTypography.title1(Colors.white)
                        .copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.s2),
            Text(subtitle, style: AppTypography.callout(Colors.white70)),
            if (metrics.isNotEmpty) ...[
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
