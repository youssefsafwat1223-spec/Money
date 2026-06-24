import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/app_lucide_icons.dart';
import 'app_button.dart';

class AppErrorState extends StatelessWidget {
  const AppErrorState({
    super.key,
    required this.title,
    required this.description,
    this.icon,
    this.retryLabel,
    this.onRetry,
  });

  final String title;
  final String description;
  final IconData? icon;
  final String? retryLabel;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;

    return Padding(
      padding: const EdgeInsets.all(AppSpacing.gutter),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 78,
              height: 78,
              decoration: BoxDecoration(
                color: c.dangerBg,
                borderRadius: BorderRadius.circular(AppRadius.xlarge),
                border: Border.all(color: c.danger.withValues(alpha: 0.22)),
              ),
              child: Icon(
                icon ?? AppLucideIcons.alertTriangle,
                color: c.danger,
                size: 34,
              ),
            ),
            const SizedBox(height: AppSpacing.s5),
            Text(
              title,
              textAlign: TextAlign.center,
              style: AppTypography.title2(c.textPrimary),
            ),
            const SizedBox(height: AppSpacing.s2),
            Text(
              description,
              textAlign: TextAlign.center,
              style: AppTypography.callout(c.textSecondary),
            ),
            if (retryLabel != null && onRetry != null) ...[
              const SizedBox(height: AppSpacing.s5),
              AppSecondaryButton(
                label: retryLabel!,
                icon: Icons.refresh_rounded,
                onTap: onRetry,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
