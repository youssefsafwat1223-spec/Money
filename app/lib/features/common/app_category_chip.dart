import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';

/// شريحة تصنيف ملونة تدعم التحديد والتعطيل مع محاذاة RTL آمنة.
class AppCategoryChip extends StatelessWidget {
  const AppCategoryChip({
    super.key,
    required this.label,
    this.icon,
    this.color,
    this.selected = false,
    this.disabled = false,
    this.onTap,
  });

  final String label;
  final IconData? icon;
  final Color? color;
  final bool selected;
  final bool disabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final baseColor = color ?? c.cta;

    // الألوان الافتراضية بناءً على حالة التحديد والتعطيل
    final bg = disabled
        ? c.disabled.withValues(alpha: 0.5)
        : selected
            ? baseColor
            : baseColor.withValues(alpha: 0.12);

    final fg = disabled
        ? c.textMuted.withValues(alpha: 0.6)
        : selected
            ? c.onCta
            : baseColor;

    final border = disabled
        ? c.border.withValues(alpha: 0.5)
        : selected
            ? Colors.transparent
            : baseColor.withValues(alpha: 0.2);

    final isInteractive = !disabled && onTap != null;

    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(AppRadius.pill),
      child: InkWell(
        onTap: isInteractive ? onTap : null,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        child: Container(
          padding: const EdgeInsetsDirectional.symmetric(
            horizontal: AppSpacing.s3,
            vertical: AppSpacing.s2,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            border: Border.all(color: border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 16, color: fg),
                const SizedBox(width: AppSpacing.s2),
              ],
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.caption(fg).copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
