import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/category_glyph.dart';
import '../../core/utils/category_palette.dart';
import '../cards/brand_mark.dart';
import 'category_catalog.dart';

/// نبرة التايل لما يكون أيقونة: [solid] لون ممتلئ وأيقونة بيضا، [soft] نفس
/// اللون بشفافية وأيقونة بلونه.
enum AppAvatarTone { solid, soft }

/// التايل المربّع الوحيد في التطبيق — براند / تصنيف / أيقونة.
///
/// كل الشاشات بتستخدمه بدل ما كل شاشة ترسم `Container` بمقاسها ونصف قطرها
/// ولونها. الشكل واحد: سوبر-إليبس (شكل أيقونات iOS) بنصف قطر = المقاس × 0.3،
/// والمقاسات من [AppSpacing] (`avatarSm` 32 / `avatar` 40 / `avatarLg` 56).
class AppAvatar extends StatelessWidget {
  /// شعار علامة تجارية — بيرجع لحرف/تصنيف تلقائيًا لو مفيش شعار.
  const AppAvatar.brand({
    super.key,
    required String name,
    String? logoUrl,
    this.size = AppSpacing.avatar,
  })  : _brandName = name,
        _logoUrl = logoUrl,
        _category = null,
        _iconName = null,
        _label = null,
        _icon = null,
        _color = null,
        _tone = AppAvatarTone.solid;

  /// تايل تصنيف — إيموجي التصنيف على لونه الثابت، أو أول حرف من [merchantName].
  const AppAvatar.category({
    super.key,
    CategoryView? category,
    String? iconName,
    String? merchantName,
    Color? color,
    this.size = AppSpacing.avatar,
  })  : _brandName = null,
        _logoUrl = null,
        _category = category,
        _iconName = iconName,
        _label = merchantName,
        _icon = null,
        _color = color,
        _tone = AppAvatarTone.solid;

  /// تايل أيقونة عام (إعدادات، حالات، إجراءات).
  const AppAvatar.icon({
    super.key,
    required IconData icon,
    Color? color,
    AppAvatarTone tone = AppAvatarTone.solid,
    this.size = AppSpacing.avatar,
  })  : _brandName = null,
        _logoUrl = null,
        _category = null,
        _iconName = null,
        _label = null,
        _icon = icon,
        _color = color,
        _tone = tone;

  final String? _brandName;
  final String? _logoUrl;
  final CategoryView? _category;
  final String? _iconName;
  final String? _label;
  final IconData? _icon;
  final Color? _color;
  final AppAvatarTone _tone;

  final double size;

  /// شكل التايل الموحّد — يُستخدم كمان في [BrandMark] عشان الاتنين يقروا واحد.
  static ShapeBorder shapeFor(double size) => RoundedSuperellipseBorder(
        borderRadius: BorderRadius.circular(size * 0.3),
      );

  @override
  Widget build(BuildContext context) {
    if (_brandName != null) {
      return BrandMark(name: _brandName, logoUrl: _logoUrl, size: size);
    }

    final c = context.colors;
    final resolvedIconName = _iconName ?? _category?.iconName;
    final initial = _initial(_label);
    final tileColor = _icon != null
        ? (_color ?? c.primary)
        : resolvedIconName != null
            ? categoryTileColor(resolvedIconName)
            : (_color ?? _category?.color ?? c.primary);
    final isSoft = _tone == AppAvatarTone.soft;

    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: ShapeDecoration(
        color: isSoft ? tileColor.withValues(alpha: 0.12) : tileColor,
        shape: shapeFor(size),
      ),
      child: _icon != null
          ? Icon(
              _icon,
              color: isSoft ? tileColor : Colors.white,
              size: size * 0.46,
            )
          : initial != null
              ? Text(
                  initial,
                  textDirection: TextDirection.ltr,
                  style: AppTypography.title2(Colors.white).copyWith(
                    fontSize: size * 0.40,
                    fontWeight: FontWeight.w700,
                  ),
                )
              : CategoryGlyph(
                  name: resolvedIconName ?? 'receipt-text',
                  size: size * 0.46,
                  color: Colors.white,
                ),
    );
  }

  static String? _initial(String? value) {
    final text = value?.trim();
    if (text == null || text.isEmpty) return null;
    return text.characters.first.toUpperCase();
  }
}
