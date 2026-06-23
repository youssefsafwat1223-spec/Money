import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/app_lucide_icons.dart';

enum AppInsightType { info, ai, warning, success, danger }

/// بطاقة رؤية/تنبيه — تدعم أنواعًا متعددة بألوان دلالية.
///
/// استخدم [AppInsightType.ai] فقط لرؤى الذكاء الاصطناعي (amber tint).
/// لا تستخدم [AppInsightType.danger] لزيادات الإنفاق العادية.
class AppInsightCard extends StatelessWidget {
  const AppInsightCard({
    super.key,
    required this.type,
    required this.title,
    required this.message,
    this.icon,
    this.ctaLabel,
    this.onCta,
    this.onTap,
  });

  final AppInsightType type;
  final String title;
  final String message;
  final IconData? icon;
  final String? ctaLabel;
  final VoidCallback? onCta;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = _color(type, c);
    final effectiveIcon = icon ?? _defaultIcon(type);

    Widget card = Container(
      padding: const EdgeInsets.all(AppSpacing.s4),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: color.withValues(alpha: 0.20)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: Icon(effectiveIcon, size: 20, color: color),
          ),
          const SizedBox(width: AppSpacing.s3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppTypography.bodyStrong(c.textPrimary)),
                const SizedBox(height: 4),
                Text(message, style: AppTypography.caption(c.textMuted)),
                if (ctaLabel != null && onCta != null) ...[
                  const SizedBox(height: AppSpacing.s3),
                  GestureDetector(
                    onTap: onCta,
                    child: Text(
                      ctaLabel!,
                      style: AppTypography.caption(color)
                          .copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );

    if (onTap != null) {
      card = GestureDetector(onTap: onTap, child: card);
    }

    return card;
  }

  static Color _color(AppInsightType type, AppColors c) => switch (type) {
        AppInsightType.info => c.cta,
        AppInsightType.ai => c.accent,
        AppInsightType.warning => c.warning,
        AppInsightType.success => c.success,
        AppInsightType.danger => c.danger,
      };

  static IconData _defaultIcon(AppInsightType type) => switch (type) {
        AppInsightType.info => AppLucideIcons.shapes,
        AppInsightType.ai => AppLucideIcons.sun,
        AppInsightType.warning => AppLucideIcons.alertTriangle,
        AppInsightType.success => AppLucideIcons.shieldCheck,
        AppInsightType.danger => AppLucideIcons.alertTriangle,
      };
}
