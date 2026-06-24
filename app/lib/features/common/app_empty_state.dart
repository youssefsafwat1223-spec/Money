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
      padding: const EdgeInsets.symmetric(
        horizontal: 0,
        vertical: AppSpacing.s7,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          illustration ??
              Container(
                width: 78,
                height: 78,
                decoration: BoxDecoration(
                  color: c.ctaSoft,
                  borderRadius: BorderRadius.circular(AppRadius.xlarge),
                  border: Border.all(color: c.cta.withValues(alpha: 0.16)),
                ),
                child: Icon(icon, size: 32, color: c.cta),
              ),
          const SizedBox(height: AppSpacing.s4),
          Text(
            title,
            textAlign: TextAlign.center,
            style: AppTypography.title2(c.textPrimary),
          ),
          const SizedBox(height: AppSpacing.s2),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: AppTypography.callout(c.textSecondary),
          ),
          if (primaryLabel != null && onPrimary != null) ...[
            const SizedBox(height: AppSpacing.s5),
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
