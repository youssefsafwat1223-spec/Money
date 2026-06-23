import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import 'app_card.dart';

class AppBudgetProgressCard extends StatelessWidget {
  const AppBudgetProgressCard({
    super.key,
    required this.title,
    required this.spentText,
    required this.limitText,
    required this.progress,
    this.icon,
    this.color,
  });

  final String title;
  final String spentText;
  final String limitText;
  final double progress;
  final IconData? icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final pct = progress.clamp(0.0, 1.0);
    final safeColor = color ?? c.cta;
    
    final trackColor = safeColor.withValues(alpha: 0.15);
    final isExceeded = progress > 1.0;
    final barColor = isExceeded ? c.danger : safeColor;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 18, color: safeColor),
                const SizedBox(width: AppSpacing.s2),
              ],
              Expanded(
                child: Text(
                  title,
                  style: AppTypography.bodyStrong(c.textPrimary),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s4),
          LinearProgressIndicator(
            value: pct,
            backgroundColor: trackColor,
            valueColor: AlwaysStoppedAnimation(barColor),
            minHeight: 8,
            borderRadius: BorderRadius.circular(4),
          ),
          const SizedBox(height: AppSpacing.s3),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(spentText, style: AppTypography.caption(barColor).copyWith(fontWeight: FontWeight.bold)),
              Text(limitText, style: AppTypography.caption(c.textMuted)),
            ],
          ),
        ],
      ),
    );
  }
}
