import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/app_lucide_icons.dart';
import 'category_catalog.dart';

class CategoryAvatar extends StatelessWidget {
  const CategoryAvatar({
    super.key,
    this.merchantName,
    this.category,
    this.icon,
    this.color,
    this.label,
    this.size = 44,
  });

  final String? merchantName;
  final CategoryView? category;
  final IconData? icon;
  final Color? color;
  final String? label;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final resolvedColor = color ?? category?.color ?? c.primary;
    final initial = _initial(merchantName ?? label);

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: initial != null
            ? c.surfaceMuted.withValues(alpha: 0.72)
            : resolvedColor.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(size * 0.35),
        border: Border.all(
          color: initial != null
              ? c.border
              : resolvedColor.withValues(alpha: 0.24),
          width: 1,
        ),
      ),
      alignment: Alignment.center,
      child: initial != null
          ? Text(
              initial,
              textDirection: TextDirection.ltr,
              style: AppTypography.title2(c.textPrimary).copyWith(
                fontSize: size * 0.42,
                fontWeight: FontWeight.w800,
              ),
            )
          : Icon(
              icon ?? category?.icon ?? AppLucideIcons.shapes,
              color: resolvedColor,
              size: size * 0.46,
            ),
    );
  }

  static String? _initial(String? value) {
    final text = value?.trim();
    if (text == null || text.isEmpty) return null;
    return text.characters.first.toUpperCase();
  }
}
