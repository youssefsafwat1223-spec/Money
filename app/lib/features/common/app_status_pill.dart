import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';

enum AppStatusTone {
  neutral,
  success,
  warning,
  danger,
  info,
  pending,
  confirmed
}

class AppStatusPill extends StatelessWidget {
  const AppStatusPill({
    super.key,
    required this.label,
    this.tone = AppStatusTone.neutral,
    this.icon,
    this.compact = false,
  });

  final String label;
  final AppStatusTone tone;
  final IconData? icon;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final colors = _colors(c, tone);

    return Semantics(
      label: label,
      child: Container(
        padding: EdgeInsetsDirectional.symmetric(
          horizontal: compact ? AppSpacing.s2 : AppSpacing.s3,
          vertical: compact ? 3 : AppSpacing.s1,
        ),
        decoration: BoxDecoration(
          color: colors.background,
          borderRadius: BorderRadius.circular(AppRadius.pill),
          border: Border.all(color: colors.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: compact ? 12 : 14, color: colors.foreground),
              const SizedBox(width: AppSpacing.s1),
            ],
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: (compact
                      ? AppTypography.micro(colors.foreground)
                      : AppTypography.caption(colors.foreground))
                  .copyWith(fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }

  static _PillColors _colors(AppColors c, AppStatusTone tone) {
    final effectiveTone =
        tone == AppStatusTone.pending ? AppStatusTone.warning : tone;
    final resolvedTone = effectiveTone == AppStatusTone.confirmed
        ? AppStatusTone.success
        : effectiveTone;

    return switch (resolvedTone) {
      AppStatusTone.success => _PillColors(
          background: c.successBg,
          foreground: c.success,
          border: c.success.withValues(alpha: 0.24),
        ),
      AppStatusTone.warning => _PillColors(
          background: c.warningBg,
          foreground: c.warning,
          border: c.warning.withValues(alpha: 0.26),
        ),
      AppStatusTone.danger => _PillColors(
          background: c.dangerBg,
          foreground: c.danger,
          border: c.danger.withValues(alpha: 0.24),
        ),
      AppStatusTone.info => _PillColors(
          background: c.infoBg,
          foreground: c.info,
          border: c.info.withValues(alpha: 0.24),
        ),
      AppStatusTone.neutral => _PillColors(
          background: c.surfaceMuted,
          foreground: c.textSecondary,
          border: c.border,
        ),
      AppStatusTone.pending => throw StateError('pending is normalized above'),
      AppStatusTone.confirmed =>
        throw StateError('confirmed is normalized above'),
    };
  }
}

class AppBadge extends AppStatusPill {
  const AppBadge({
    super.key,
    required super.label,
    super.tone,
    super.icon,
    super.compact = true,
  });
}

class _PillColors {
  const _PillColors({
    required this.background,
    required this.foreground,
    required this.border,
  });

  final Color background;
  final Color foreground;
  final Color border;
}
