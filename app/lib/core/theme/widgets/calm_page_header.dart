import 'package:flutter/material.dart';

import '../app_colors.dart';
import '../app_spacing.dart';
import '../app_typography.dart';

/// One cell in a [CalmPageHeader] metric strip.
class CalmMetric {
  const CalmMetric({required this.label, required this.value});
  final String label;
  final String value;
}

/// CalmPageHeader — the shared top-of-page pattern for the whole app
/// (docs/MALI_DESIGN_SYSTEM.md).
///
/// A blue hero band (title + optional subtitle, leading/trailing action, big
/// amount statement, metric strip) followed by a rounded-top "sheet lip" in the
/// page background colour — so the scrollable content below curves off the blue
/// instead of meeting it at a hard straight edge. White content on the blue.
/// Every screen uses this one widget — edit it here and every page updates.
class CalmPageHeader extends StatelessWidget {
  const CalmPageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.amount,
    this.currency,
    this.metrics,
    this.topInset = AppSpacing.headerTopInset,
    this.useSafeAreaTop = true,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;

  /// Big statement amount (e.g. the period total). Rendered white on the blue.
  final String? amount;

  /// Smaller, secondary currency next to [amount].
  final String? currency;

  final List<CalmMetric>? metrics;

  /// Fallback top padding when [useSafeAreaTop] is false (e.g. the header is
  /// embedded, not at the screen top).
  final double topInset;

  /// When true (screens that extend under the status bar) the top padding is
  /// the real device safe-area inset + a small gap, so the title always clears
  /// the notch / Dynamic Island. A fixed inset can't — the island is ~59px.
  final bool useSafeAreaTop;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final topPad = useSafeAreaTop
        ? MediaQuery.paddingOf(context).top + AppSpacing.s2
        : topInset;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          stops: const [0.0, 0.55, 1.0],
          colors: isDark
              ? const [Color(0xFF071634), Color(0xFF0E3A86), Color(0xFF1E74F0)]
              : const [Color(0xFF1E74F0), Color(0xFF3E8CF7), Color(0xFF7FB2FF)],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
                AppSpacing.gutter, topPad, AppSpacing.gutter, AppSpacing.s5),
            // White content on the blue hero. Icon leading/trailing that don't
            // hardcode a colour inherit white from here.
            child: IconTheme(
              data: const IconThemeData(color: Colors.white),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (leading != null) ...[
                        leading!,
                        const SizedBox(width: AppSpacing.s2),
                      ],
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              title,
                              style: AppTypography.calmTitle(Colors.white)
                                  .copyWith(fontSize: 24, letterSpacing: -0.5),
                            ),
                            if (subtitle != null && subtitle!.isNotEmpty) ...[
                              const SizedBox(height: 3),
                              Text(
                                subtitle!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppTypography.caption(
                                    Colors.white.withValues(alpha: 0.72)),
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (trailing != null) trailing!,
                    ],
                  ),
                  if (amount != null) ...[
                    const SizedBox(height: AppSpacing.s3),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: AlignmentDirectional.centerStart,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text(
                            amount!,
                            style: AppTypography.balanceHero(Colors.white)
                                .copyWith(fontSize: 44),
                          ),
                          if (currency != null && currency!.isNotEmpty) ...[
                            const SizedBox(width: 8),
                            Text(
                              currency!,
                              style: AppTypography.title2(
                                      Colors.white.withValues(alpha: 0.82))
                                  .copyWith(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w500),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                  if (metrics != null && metrics!.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.s3),
                    _MetricStrip(metrics: metrics!),
                  ],
                ],
              ),
            ),
          ),
          // Rounded-top sheet lip in the page background — the content below
          // curves off the blue instead of meeting a hard straight edge.
          Container(
            height: 22,
            decoration: BoxDecoration(
              color: c.bg,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(26)),
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricStrip extends StatelessWidget {
  const _MetricStrip({required this.metrics});
  final List<CalmMetric> metrics;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
          vertical: AppSpacing.s4, horizontal: AppSpacing.s2),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        children: [
          for (var i = 0; i < metrics.length; i++) ...[
            if (i > 0)
              Container(
                  width: 1,
                  height: 30,
                  color: Colors.white.withValues(alpha: 0.2)),
            Expanded(
              child: Column(
                children: [
                  Text(
                    metrics[i].value,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.bodyStrong(Colors.white),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    metrics[i].label,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    // 11px per the mockup `.metastrip span` (caption is 12).
                    style: AppTypography.caption(
                            Colors.white.withValues(alpha: 0.72))
                        .copyWith(fontSize: 11),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
