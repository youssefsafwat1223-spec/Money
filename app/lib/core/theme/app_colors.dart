import 'package:flutter/material.dart';

/// AppColors — Premium Minimalist Fintech Color System for Mali.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.bg,
    required this.surface,
    required this.surfaceElevated,
    required this.primary,
    required this.onPrimary,
    required this.cta,
    required this.onCta,
    required this.ctaSoft,
    required this.accent,
    required this.income,
    required this.expense,
    required this.success,
    required this.warning,
    required this.danger,
    required this.info,
    required this.neutral,
    required this.disabled,
    required this.border,
    required this.divider,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.onSuccess,
    required this.onDanger,
    required this.onWarning,
    required this.onInfo,
    // Legacy tokens for backward compatibility
    required this.gradA,
    required this.gradB,
  });

  // ===== Surfaces =====
  final Color bg;
  final Color surface;
  final Color surfaceElevated;

  // ===== Brand / Interactive =====
  /// Brand text/elements. Safe contrast in light/dark.
  /// IMPORTANT: Never use as a button background without `onPrimary` as foreground!
  final Color primary;
  /// The correct foreground color to use when `primary` is the background.
  final Color onPrimary;

  /// Primary interactive CTA color (Mali Blue).
  final Color cta;
  /// Foreground for CTA backgrounds (always white).
  final Color onCta;
  /// Tinted background for CTA.
  final Color ctaSoft;

  final Color accent;

  // ===== Semantics =====
  final Color income;
  final Color expense;
  final Color success;
  final Color warning;
  final Color danger;
  final Color info;
  final Color neutral;
  final Color disabled;

  // ===== Contrast Safe Pairings =====
  final Color onSuccess;
  final Color onDanger;
  final Color onWarning;
  final Color onInfo;

  // ===== Lines =====
  final Color border;
  final Color divider;

  // ===== Typography =====
  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;

  // ===== Legacy Backwards Compatibility =====
  final Color gradA;
  final Color gradB;
  
  Color get surface2 => surfaceElevated;
  Color get textMain => textPrimary;
  Color get textSec => textSecondary;
  Color get textLight => textMuted;

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

  // ===== Light Mode =====
  static const AppColors light = AppColors(
    bg: Color(0xFFF4F7FA),
    surface: Color(0xFFFFFFFF),
    surfaceElevated: Color(0xFFFFFFFF), // Can use shadow for elevation
    primary: Color(0xFF062635),
    onPrimary: Color(0xFFFFFFFF),
    cta: Color(0xFF006B8F),
    onCta: Color(0xFFFFFFFF),
    ctaSoft: Color(0xFFE6F4F9),
    accent: Color(0xFF2F80A8),
    income: Color(0xFF0F9F6E),
    expense: Color(0xFFD93D54),
    success: Color(0xFF0F9F6E),
    warning: Color(0xFFE06F4F),
    danger: Color(0xFFD93D54),
    info: Color(0xFF2F80A8),
    neutral: Color(0xFF64748B),
    disabled: Color(0xFFCBD5E1),
    border: Color(0xFFD7E1E8),
    divider: Color(0xFFE2E8F0),
    textPrimary: Color(0xFF062635),
    textSecondary: Color(0xFF64748B),
    textMuted: Color(0xFF94A3B8),
    onSuccess: Color(0xFFFFFFFF),
    onDanger: Color(0xFFFFFFFF),
    onWarning: Color(0xFFFFFFFF),
    onInfo: Color(0xFFFFFFFF),
    gradA: Color(0xFF006B8F),
    gradB: Color(0xFF062635),
  );

  // ===== Dark Mode =====
  static const AppColors dark = AppColors(
    bg: Color(0xFF0C0D11),              // Obsidian base
    surface: Color(0xFF141623),         // Slate card fill
    surfaceElevated: Color(0xFF1C1E2F), // Popups / Sheets
    primary: Color(0xFFFFFFFF),
    onPrimary: Color(0xFF0C0D11),
    cta: Color(0xFF5488FE),             // Electric blue CTA
    onCta: Color(0xFFFFFFFF),
    ctaSoft: Color(0xFF0C2450),         // Soft tinted CTA
    accent: Color(0xFF238AFF),          // Accent neon blue
    income: Color(0xFF28C99B),          // Emerald success
    expense: Color(0xFFFF6B73),          // Watermelon danger
    success: Color(0xFF28C99B),
    warning: Color(0xFFFF8A65),          // Luminous orange coral warning
    danger: Color(0xFFFF6B73),
    info: Color(0xFF238AFF),
    neutral: Color(0xFF6F8190),
    disabled: Color(0xFF193044),
    border: Color(0xFF1E2235),          // Thin borders
    divider: Color(0xFF121422),         // Dividers
    textPrimary: Color(0xFFFFFFFF),
    textSecondary: Color(0xFFA8B7C4),
    textMuted: Color(0xFF6F8190),
    onSuccess: Color(0xFFFFFFFF),
    onDanger: Color(0xFFFFFFFF),
    onWarning: Color(0xFF0C0D11),        // Dark foreground for soft orange coral
    onInfo: Color(0xFFFFFFFF),
    gradA: Color(0xFF0C2450),
    gradB: Color(0xFF0C0D11),
  );

  @override
  AppColors copyWith({
    Color? bg,
    Color? surface,
    Color? surfaceElevated,
    Color? primary,
    Color? onPrimary,
    Color? cta,
    Color? onCta,
    Color? ctaSoft,
    Color? accent,
    Color? income,
    Color? expense,
    Color? success,
    Color? warning,
    Color? danger,
    Color? info,
    Color? neutral,
    Color? disabled,
    Color? border,
    Color? divider,
    Color? textPrimary,
    Color? textSecondary,
    Color? textMuted,
    Color? onSuccess,
    Color? onDanger,
    Color? onWarning,
    Color? onInfo,
    Color? gradA,
    Color? gradB,
  }) {
    return AppColors(
      bg: bg ?? this.bg,
      surface: surface ?? this.surface,
      surfaceElevated: surfaceElevated ?? this.surfaceElevated,
      primary: primary ?? this.primary,
      onPrimary: onPrimary ?? this.onPrimary,
      cta: cta ?? this.cta,
      onCta: onCta ?? this.onCta,
      ctaSoft: ctaSoft ?? this.ctaSoft,
      accent: accent ?? this.accent,
      income: income ?? this.income,
      expense: expense ?? this.expense,
      success: success ?? this.success,
      warning: warning ?? this.warning,
      danger: danger ?? this.danger,
      info: info ?? this.info,
      neutral: neutral ?? this.neutral,
      disabled: disabled ?? this.disabled,
      border: border ?? this.border,
      divider: divider ?? this.divider,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textMuted: textMuted ?? this.textMuted,
      onSuccess: onSuccess ?? this.onSuccess,
      onDanger: onDanger ?? this.onDanger,
      onWarning: onWarning ?? this.onWarning,
      onInfo: onInfo ?? this.onInfo,
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
      surfaceElevated: Color.lerp(surfaceElevated, other.surfaceElevated, t)!,
      primary: Color.lerp(primary, other.primary, t)!,
      onPrimary: Color.lerp(onPrimary, other.onPrimary, t)!,
      cta: Color.lerp(cta, other.cta, t)!,
      onCta: Color.lerp(onCta, other.onCta, t)!,
      ctaSoft: Color.lerp(ctaSoft, other.ctaSoft, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      income: Color.lerp(income, other.income, t)!,
      expense: Color.lerp(expense, other.expense, t)!,
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      info: Color.lerp(info, other.info, t)!,
      neutral: Color.lerp(neutral, other.neutral, t)!,
      disabled: Color.lerp(disabled, other.disabled, t)!,
      border: Color.lerp(border, other.border, t)!,
      divider: Color.lerp(divider, other.divider, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
      onSuccess: Color.lerp(onSuccess, other.onSuccess, t)!,
      onDanger: Color.lerp(onDanger, other.onDanger, t)!,
      onWarning: Color.lerp(onWarning, other.onWarning, t)!,
      onInfo: Color.lerp(onInfo, other.onInfo, t)!,
      gradA: Color.lerp(gradA, other.gradA, t)!,
      gradB: Color.lerp(gradB, other.gradB, t)!,
    );
  }
}

extension AppColorsX on BuildContext {
  AppColors get colors => Theme.of(this).extension<AppColors>()!;
}
