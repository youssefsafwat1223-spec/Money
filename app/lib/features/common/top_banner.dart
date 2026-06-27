import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_typography.dart';

/// Shows a dismissible error message as a banner pinned to the **top** of the
/// screen (a [MaterialBanner], unlike the bottom snackbars used elsewhere).
/// Auto-dismisses after a few seconds.
void showTopError(BuildContext context, String message) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final c = context.colors;
  messenger.clearMaterialBanners();
  messenger.showMaterialBanner(
    MaterialBanner(
      backgroundColor: Colors.transparent,
      dividerColor: Colors.transparent,
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
      leadingPadding: EdgeInsets.zero,
      content: _TopBannerSurface(
        color: c.danger,
        background: c.dangerBg,
        icon: Icons.error_outline_rounded,
        message: message,
      ),
      actions: [
        TextButton(
          onPressed: messenger.hideCurrentMaterialBanner,
          child: Text('إغلاق', style: AppTypography.bodyStrong(c.danger)),
        ),
      ],
    ),
  );
  Future.delayed(
    const Duration(seconds: 5),
    messenger.hideCurrentMaterialBanner,
  );
}

/// Like [showTopError] but a neutral/success tone — for informational notices
/// such as "we found two operations in this message".
void showTopInfo(BuildContext context, String message) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final c = context.colors;
  messenger.clearMaterialBanners();
  messenger.showMaterialBanner(
    MaterialBanner(
      backgroundColor: Colors.transparent,
      dividerColor: Colors.transparent,
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
      leadingPadding: EdgeInsets.zero,
      content: _TopBannerSurface(
        color: c.success,
        background: c.successBg,
        icon: Icons.check_circle_outline_rounded,
        message: message,
      ),
      actions: [
        TextButton(
          onPressed: messenger.hideCurrentMaterialBanner,
          child: Text('إغلاق', style: AppTypography.bodyStrong(c.success)),
        ),
      ],
    ),
  );
  Future.delayed(
    const Duration(seconds: 5),
    messenger.hideCurrentMaterialBanner,
  );
}

class _TopBannerSurface extends StatelessWidget {
  const _TopBannerSurface({
    required this.color,
    required this.background,
    required this.icon,
    required this.message,
  });

  final Color color;
  final Color background;
  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.20)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.14),
            blurRadius: 22,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: AppTypography.callout(c.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}
