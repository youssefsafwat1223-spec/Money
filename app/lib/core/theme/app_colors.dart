import 'package:flutter/material.dart';

/// رموز الألوان (Color Tokens) — من DESIGN_SYSTEM.md ("Vibrant Fintech").
///
/// تُقرأ في الواجهة عبر `context.colors`. مُنفّذة كـ [ThemeExtension] حتى
/// تتبدّل تلقائياً بين الوضعين Light/Dark دون كود إضافي.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.bg,
    required this.surface,
    required this.surface2,
    required this.primary,
    required this.gradA,
    required this.gradB,
    required this.accent,
    required this.success,
    required this.danger,
    required this.textMain,
    required this.textLight,
    required this.border,
  });

  final Color bg;
  final Color surface;
  final Color surface2;
  final Color primary;
  final Color gradA;
  final Color gradB;
  final Color accent;
  final Color success;
  final Color danger;
  final Color textMain;
  final Color textLight;
  final Color border;

  /// التدرّج الرئيسي للـ headers/الأزرار (الطاقة الحيوية).
  LinearGradient get primaryGradient => LinearGradient(
        colors: [gradA, gradB],
        begin: Alignment.topRight,
        end: Alignment.bottomLeft,
      );

  /// لون حالة الميزانية حسب نسبة الاستخدام (0..1+).
  Color budgetState(double ratio) {
    if (ratio >= 1.0) return danger;
    if (ratio >= 0.8) return accent;
    return success;
  }

  // ☀️ الوضع الفاتح — Navy + Amber (الهوية المعتمدة)
  static const AppColors light = AppColors(
    bg: Color(0xFFEEF2F7),
    surface: Color(0xFFFFFFFF),
    surface2: Color(0xFFEAF0F6),
    primary: Color(0xFF0A2540),
    gradA: Color(0xFF0A2540),
    gradB: Color(0xFF1A3F66),
    accent: Color(0xFFFFB300),
    success: Color(0xFF16A968),
    danger: Color(0xFFE5484D),
    textMain: Color(0xFF0A2540),
    textLight: Color(0xFF67768A),
    border: Color(0xFFE2EAF2),
  );

  // 🌙 الوضع الداكن — Dark premium Mali tokens.
  // أزرق أهدأ وأعمق (أقل سطوعًا/إجهادًا) مع خلفية أعمق وتباين أوضح.
  static const AppColors dark = AppColors(
    bg: Color(0xFF080F1A),
    surface: Color(0xFF111C2C),
    surface2: Color(0xFF18293D),
    primary: Color(0xFF3D7CC4),
    gradA: Color(0xFF2F5F9C),
    gradB: Color(0xFF0B1B30),
    accent: Color(0xFFF5A623),
    success: Color(0xFF22C57E),
    danger: Color(0xFFE8606B),
    textMain: Color(0xFFEAF1F8),
    textLight: Color(0xFF93A4B8),
    border: Color(0x1FFFFFFF),
  );

  @override
  AppColors copyWith({
    Color? bg,
    Color? surface,
    Color? surface2,
    Color? primary,
    Color? gradA,
    Color? gradB,
    Color? accent,
    Color? success,
    Color? danger,
    Color? textMain,
    Color? textLight,
    Color? border,
  }) {
    return AppColors(
      bg: bg ?? this.bg,
      surface: surface ?? this.surface,
      surface2: surface2 ?? this.surface2,
      primary: primary ?? this.primary,
      gradA: gradA ?? this.gradA,
      gradB: gradB ?? this.gradB,
      accent: accent ?? this.accent,
      success: success ?? this.success,
      danger: danger ?? this.danger,
      textMain: textMain ?? this.textMain,
      textLight: textLight ?? this.textLight,
      border: border ?? this.border,
    );
  }

  @override
  AppColors lerp(ThemeExtension<AppColors>? other, double t) {
    if (other is! AppColors) return this;
    return AppColors(
      bg: Color.lerp(bg, other.bg, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surface2: Color.lerp(surface2, other.surface2, t)!,
      primary: Color.lerp(primary, other.primary, t)!,
      gradA: Color.lerp(gradA, other.gradA, t)!,
      gradB: Color.lerp(gradB, other.gradB, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      success: Color.lerp(success, other.success, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      textMain: Color.lerp(textMain, other.textMain, t)!,
      textLight: Color.lerp(textLight, other.textLight, t)!,
      border: Color.lerp(border, other.border, t)!,
    );
  }
}

/// وصول سريع للألوان من الـ context.
extension AppColorsX on BuildContext {
  AppColors get colors => Theme.of(this).extension<AppColors>()!;
}
