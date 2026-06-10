import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// الطباعة — IBM Plex Sans Arabic (من DESIGN_SYSTEM.md).
///
/// نستخدم `GoogleFonts.getFont('IBM Plex Sans Arabic', ...)` بالاسم النصّي
/// لتفادي أي اختلاف في أسماء الـ getters المولّدة. عند الإنتاج يُفضّل تضمين
/// ملفات الخط محلياً (bundled) بدل التحميل وقت التشغيل.
class AppTypography {
  AppTypography._();

  static const String fontFamilyName = 'IBM Plex Sans Arabic';

  /// أرقام بعرض ثابت — إلزامية للمبالغ المالية.
  static const List<FontFeature> _tabular = [FontFeature.tabularFigures()];

  static TextStyle _plex({
    required double size,
    required FontWeight weight,
    required double height,
    double letterSpacing = 0,
    bool tabular = false,
    Color? color,
  }) {
    return GoogleFonts.getFont(
      fontFamilyName,
      fontSize: size,
      fontWeight: weight,
      height: height,
      letterSpacing: letterSpacing,
      color: color,
      fontFeatures: tabular ? _tabular : null,
    );
  }

  // ===== أنماط نصّية مسمّاة =====
  static TextStyle amountHero(Color c) => _plex(
      size: 40,
      weight: FontWeight.w700,
      height: 1.10,
      letterSpacing: -0.5,
      tabular: true,
      color: c);
  static TextStyle display(Color c) => _plex(
      size: 34,
      weight: FontWeight.w700,
      height: 1.18,
      letterSpacing: -0.5,
      color: c);
  static TextStyle title1(Color c) => _plex(
      size: 28,
      weight: FontWeight.w700,
      height: 1.21,
      letterSpacing: -0.4,
      color: c);
  static TextStyle title2(Color c) => _plex(
      size: 22,
      weight: FontWeight.w600,
      height: 1.27,
      letterSpacing: -0.3,
      color: c);
  static TextStyle headline(Color c) =>
      _plex(size: 18, weight: FontWeight.w600, height: 1.33, color: c);
  static TextStyle body(Color c) =>
      _plex(size: 16, weight: FontWeight.w400, height: 1.50, color: c);
  static TextStyle bodyStrong(Color c) =>
      _plex(size: 16, weight: FontWeight.w500, height: 1.50, color: c);
  static TextStyle callout(Color c) =>
      _plex(size: 15, weight: FontWeight.w400, height: 1.46, color: c);
  static TextStyle subhead(Color c) =>
      _plex(size: 14, weight: FontWeight.w500, height: 1.43, color: c);
  static TextStyle footnote(Color c) =>
      _plex(size: 13, weight: FontWeight.w400, height: 1.38, color: c);
  static TextStyle caption(Color c) =>
      _plex(size: 12, weight: FontWeight.w500, height: 1.33, color: c);

  /// يبني [TextTheme] كامل بلون النص الأساسي.
  static TextTheme textTheme(Color main) => TextTheme(
        displayLarge: display(main),
        headlineLarge: title1(main),
        headlineMedium: title2(main),
        titleLarge: headline(main),
        bodyLarge: body(main),
        bodyMedium: callout(main),
        labelLarge: subhead(main),
        bodySmall: footnote(main),
        labelSmall: caption(main),
      );
}
