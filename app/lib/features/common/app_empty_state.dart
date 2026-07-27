import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import 'app_button.dart';

/// حالة فارغة قياسية — أيقونة + عنوان + وصف + أزرار اختيارية.
///
/// تعمل في داشبورد، معاملات، تقارير، ميزانيات، إعدادات.
/// آمنة في وضع RTL لأن المحاذاة مركزية.
class AppEmptyState extends StatelessWidget {
  const AppEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.illustration,
    this.primaryLabel,
    this.onPrimary,
    this.secondaryLabel,
    this.onSecondary,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? illustration;
  final String? primaryLabel;
  final VoidCallback? onPrimary;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      // Compact UI system: tighter vertical rhythm, smaller art + heading.
      padding: const EdgeInsets.symmetric(
        horizontal: 0,
        vertical: AppSpacing.s5,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          illustration ??
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: c.ctaSoft,
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                  border: Border.all(color: c.cta.withValues(alpha: 0.16)),
                ),
                child: Icon(icon, size: 26, color: c.cta),
              ),
          const SizedBox(height: AppSpacing.s3),
          Text(
            title,
            textAlign: TextAlign.center,
            style: AppTypography.sectionTitle(c.textPrimary),
          ),
          const SizedBox(height: AppSpacing.s2),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: AppTypography.footnote(c.textSecondary),
          ),
          if (primaryLabel != null && onPrimary != null) ...[
            const SizedBox(height: AppSpacing.s4),
            SizedBox(
              width: double.infinity,
              child: AppPrimaryButton(
                label: primaryLabel!,
                onTap: onPrimary,
              ),
            ),
          ],
          if (secondaryLabel != null && onSecondary != null) ...[
            const SizedBox(height: AppSpacing.s3),
            AppGhostButton(
              label: secondaryLabel!,
              onTap: onSecondary,
              height: 44,
            ),
          ],
        ],
      ),
    );
  }
}
