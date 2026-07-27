import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/category_glyph.dart';
import '../../core/utils/category_palette.dart';
import 'category_catalog.dart';

class CategoryAvatar extends StatelessWidget {
  const CategoryAvatar({
    super.key,
    this.merchantName,
    this.category,
    this.icon,
    this.iconName,
    this.color,
    this.label,
    this.size = 44,
  });

  final String? merchantName;
  final CategoryView? category;
  final IconData? icon;
  final String? iconName;
  final Color? color;
  final String? label;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final initial = _initial(merchantName ?? label);
    final resolvedIconName = iconName ?? category?.iconName;
    // Fixed, deep per-category tile background (navy/brown palette) whenever we
    // know the category; otherwise fall back to a passed colour / primary.
    final resolvedColor = resolvedIconName != null
        ? categoryTileColor(resolvedIconName)
        : (color ?? category?.color ?? c.primary);

    // Solid tile — the fixed category colour as a single flat fill with a
    // white glyph, on the true Apple superellipse (RoundedSuperellipseBorder).
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: ShapeDecoration(
        color: resolvedColor,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(size * 0.3),
        ),
      ),
      child: initial != null
          ? Text(
              initial,
              textDirection: TextDirection.ltr,
              style: AppTypography.title2(Colors.white).copyWith(
                fontSize: size * 0.40,
                fontWeight: FontWeight.w700,
              ),
            )
          : resolvedIconName != null
              ? CategoryGlyph(
                  name: resolvedIconName,
                  size: size * 0.46,
                  color: Colors.white,
                )
              : Icon(
                  icon ?? Icons.category,
                  color: Colors.white,
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
