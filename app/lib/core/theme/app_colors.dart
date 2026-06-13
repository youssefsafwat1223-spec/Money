import 'package:flutter/material.dart';

/// رموز الألوان (Color Tokens) — Premium Minimalist Fintech.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.bg,
    required this.surface,
    required this.surface2,
    required this.primary,
    required this.accent,
    required this.success,
    required this.warning,
    required this.danger,
    required this.textMain,
    required this.textLight,
    required this.border,
    required this.gradA,
    required this.gradB,
  });

  final Color bg;
  final Color surface;
  final Color surface2;
  final Color primary;
  final Color accent;
  final Color success;
  final Color warning;
  final Color danger;
  final Color textMain;
  final Color textLight;
  final Color border;
  
  // Kept for backward compatibility with older components until they are migrated
  final Color gradA;
  final Color gradB;

  LinearGradient get primaryGradient => LinearGradient(
        colors: [gradA, gradB],
        begin: Alignment.topRight,
        end: Alignment.bottomLeft,
      );

  Color budgetState(double ratio) {
    if (ratio >= 1.0) return danger;
    if (ratio >= 0.8) return warning;
    return success;
  }

  // ☀️ Light Mode — Premium Minimalist
  static const AppColors light = AppColors(
    bg: Color(0xFFF7F9FA), // Soft off-white
    surface: Color(0xFFFFFFFF), // Pure white cards
    surface2: Color(0xFFF0F2F5),
    primary: Color(0xFF0A1128), // Deep ink black
    accent: Color(0xFFFFB300), // Gold/Amber CTA
    success: Color(0xFF16A968),
    warning: Color(0xFFFF9500),
    danger: Color(0xFFFF3B30),
    textMain: Color(0xFF0A1128),
    textLight: Color(0xFF8E8E93),
    border: Color(0xFFEBEBEB),
    gradA: Color(0xFF0A1128), // Mapped to primary for now
    gradB: Color(0xFF111C3D), // Mapped to primary variant
  );

  // 🌙 Dark Mode — Premium Minimalist
  static const AppColors dark = AppColors(
    bg: Color(0xFF000000), // True black
    surface: Color(0xFF151515), // Deep dark cards
    surface2: Color(0xFF1C1C1E),
    primary: Color(0xFFFFFFFF), // Crisp white text/icons
    accent: Color(0xFFFFB300), // Gold/Amber CTA
    success: Color(0xFF34C759),
    warning: Color(0xFFFF9F0A),
    danger: Color(0xFFFF453A),
    textMain: Color(0xFFFFFFFF),
    textLight: Color(0xFF98989D),
    border: Color(0xFF2C2C2E),
    gradA: Color(0xFF1C1C1E), // Mapped to dark surface
    gradB: Color(0xFF2C2C2E),
  );

  @override
  AppColors copyWith({
    Color? bg,
    Color? surface,
    Color? surface2,
    Color? primary,
    Color? accent,
    Color? success,
    Color? warning,
    Color? danger,
    Color? textMain,
    Color? textLight,
    Color? border,
    Color? gradA,
    Color? gradB,
  }) {
    return AppColors(
      bg: bg ?? this.bg,
      surface: surface ?? this.surface,
      surface2: surface2 ?? this.surface2,
      primary: primary ?? this.primary,
      accent: accent ?? this.accent,
      success: success ?? this.success,
      warning: warning ?? this.warning,
      danger: danger ?? this.danger,
      textMain: textMain ?? this.textMain,
      textLight: textLight ?? this.textLight,
      border: border ?? this.border,
      gradA: gradA ?? this.gradA,
      gradB: gradB ?? this.gradB,
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
      accent: Color.lerp(accent, other.accent, t)!,
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      textMain: Color.lerp(textMain, other.textMain, t)!,
      textLight: Color.lerp(textLight, other.textLight, t)!,
      border: Color.lerp(border, other.border, t)!,
      gradA: Color.lerp(gradA, other.gradA, t)!,
      gradB: Color.lerp(gradB, other.gradB, t)!,
    );
  }
}

extension AppColorsX on BuildContext {
  AppColors get colors => Theme.of(this).extension<AppColors>()!;
}
