import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/qirsh_visuals.dart';

/// Missing-record presentation; the owning page or sheet supplies scrolling.
class AppMissingRecordState extends StatelessWidget {
  const AppMissingRecordState({super.key, required this.message, required this.illustration});

  final String message;
  final String illustration;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(AppSpacing.gutter),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            QirshIllustration(name: illustration, width: 160, height: 120),
            const SizedBox(height: AppSpacing.s3),
            Text(message, textAlign: TextAlign.center,
                style: AppTypography.bodyStrong(context.colors.textPrimary)),
          ],
        ),
      );
}
