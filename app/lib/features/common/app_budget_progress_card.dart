import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import 'app_card.dart';

/// بطاقة تقدم الميزانية — تعرض الاسم، المصروف، الحد الأقصى، وشريط التقدم ملونًا دلاليًا.
class AppBudgetProgressCard extends StatelessWidget {
  const AppBudgetProgressCard({
    super.key,
    required this.title,
    required this.spentText,
    required this.limitText,
    required this.progress,
    this.remainingText,
    this.icon,
    this.color,
  });

  final String title;
  final String spentText;
  final String limitText;
  final double progress;
  final String? remainingText;
  final IconData? icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final pct = progress.clamp(0.0, 1.0);

    final stateColor = color ?? c.budgetState(progress);
    final trackColor = stateColor.withValues(alpha: 0.15);
    final barColor = stateColor;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 18, color: stateColor),
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
              Flexible(
                child: Text(
                  spentText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.caption(barColor).copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              if (remainingText != null) ...[
                const SizedBox(width: AppSpacing.s2),
                Flexible(
                  child: Text(
                    remainingText!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: AppTypography.caption(c.textSecondary),
                  ),
                ),
              ],
              const SizedBox(width: AppSpacing.s2),
              Flexible(
                child: Text(
                  limitText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.end,
                  style: AppTypography.caption(c.textMuted),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class BudgetProgressCard extends AppBudgetProgressCard {
  const BudgetProgressCard({
    super.key,
    required String name,
    required super.spentText,
    required super.limitText,
    required super.progress,
    super.remainingText,
    super.icon,
    super.color,
  }) : super(title: name);
}
