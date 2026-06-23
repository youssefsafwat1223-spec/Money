import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_shadows.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';

enum AppMetricStyle { neutral, positive, negative, success, warning }

/// بطاقة مقياس مالي صغيرة — عنوان + قيمة + اختياريات.
///
/// [value] يُمرَّر منسَّقًا مسبقًا. عند [privacyMode] تُعرَض `'••••'` بدلًا منه.
class AppMetricCard extends StatelessWidget {
  const AppMetricCard({
    super.key,
    required this.title,
    required this.value,
    this.subtitle,
    this.icon,
    this.style = AppMetricStyle.neutral,
    this.privacyMode = false,
  });

  final String title;
  final String value;
  final String? subtitle;
  final IconData? icon;
  final AppMetricStyle style;
  final bool privacyMode;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final accentColor = _color(style, c);
    final displayValue = privacyMode ? '••••' : value;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.s4),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: c.border),
        boxShadow: AppShadows.card,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 16, color: accentColor),
                const SizedBox(width: AppSpacing.s2),
              ],
              Expanded(
                child: Text(title, style: AppTypography.caption(c.textMuted)),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s1),
          Text(
            displayValue,
            style: AppTypography.amountSmall(accentColor),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 2),
            Text(subtitle!, style: AppTypography.caption(c.textMuted)),
          ],
        ],
      ),
    );
  }

  static Color _color(AppMetricStyle style, AppColors c) => switch (style) {
        AppMetricStyle.positive => c.success,
        AppMetricStyle.negative => c.danger,
        AppMetricStyle.success => c.success,
        AppMetricStyle.warning => c.warning,
        AppMetricStyle.neutral => c.textPrimary,
      };
}
