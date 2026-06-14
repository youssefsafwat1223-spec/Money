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

  // Light Mode — Bahama Blue brand on a crisp, airy canvas.
  static const AppColors light = AppColors(
    bg: Color(0xFFF2F7FB),
    surface: Color(0xFFFFFFFF),
    surface2: Color(0xFFE3EEF5),
    primary: Color(0xFF056A95),
    accent: Color(0xFF4F8AA6),
    success: Color(0xFF14946E),
    warning: Color(0xFFC57F2C),
    danger: Color(0xFFD4493D),
    textMain: Color(0xFF0E2230),
    textLight: Color(0xFF5C7484),
    border: Color(0xFFD5E2EB),
    gradA: Color(0xFF0789BB),
    gradB: Color(0xFF034F73),
  );

  // Dark Mode — deep midnight Bahama with luminous brand accents.
  static const AppColors dark = AppColors(
    bg: Color(0xFF02131C),
    surface: Color(0xFF081E2A),
    surface2: Color(0xFF102E3F),
    primary: Color(0xFF38B0DD),
    accent: Color(0xFF7CB1C8),
    success: Color(0xFF2BC79A),
    warning: Color(0xFFD89C5A),
    danger: Color(0xFFFF6B73),
    textMain: Color(0xFFEBF4F9),
    textLight: Color(0xFF95AEBC),
    border: Color(0xFF1C3849),
    gradA: Color(0xFF0789BB),
    gradB: Color(0xFF056A95),
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
