import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';

class AppLoadingState extends StatelessWidget {
  const AppLoadingState({super.key, this.label});

  final String? label;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: c.cta),
          if (label != null) ...[
            const SizedBox(height: AppSpacing.s4),
            Text(label!, style: AppTypography.callout(c.textMuted)),
          ],
        ],
      ),
    );
  }
}

class AppSkeletonBlock extends StatelessWidget {
  const AppSkeletonBlock({
    super.key,
    this.height = 72,
    this.width,
    this.radius = AppRadius.card,
  });

  final double height;
  final double? width;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: c.surfaceMuted.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: c.border.withValues(alpha: 0.55)),
      ),
    );
  }
}

class AppSkeletonRow extends StatelessWidget {
  const AppSkeletonRow({super.key});

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        AppSkeletonBlock(width: 44, height: 44, radius: AppRadius.xlarge),
        SizedBox(width: AppSpacing.s3),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppSkeletonBlock(height: 14, radius: AppRadius.sm),
              SizedBox(height: AppSpacing.s2),
              AppSkeletonBlock(width: 140, height: 12, radius: AppRadius.sm),
            ],
          ),
        ),
      ],
    );
  }
}
