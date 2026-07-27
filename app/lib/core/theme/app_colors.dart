import 'package:flutter/material.dart';

/// AppColors — Premium Minimalist Fintech Color System for Qirsh.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.bg,
    required this.surface,
    required this.surfaceElevated,
    required this.surfaceCard,
    required this.surfaceMuted,
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
    required this.disabledFg,
    required this.border,
    required this.divider,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.onSurface,
    required this.onSurfaceMuted,
    required this.successBg,
    required this.dangerBg,
    required this.warningBg,
    required this.infoBg,
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
  final Color surfaceCard;
  final Color surfaceMuted;

  // ===== Brand / Interactive =====
  /// Brand text/elements. Safe contrast in light/dark.
  /// IMPORTANT: Never use as a button background without `onPrimary` as foreground!
  final Color primary;

  /// The correct foreground color to use when `primary` is the background.
  final Color onPrimary;

  /// Primary interactive CTA color (Qirsh Blue).
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
  final Color disabledFg;

  // ===== Contrast Safe Pairings =====
  final Color onSurface;
  final Color onSurfaceMuted;
  final Color successBg;
  final Color dangerBg;
  final Color warningBg;
  final Color infoBg;
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
  Color get cardSurface => surfaceCard;
  Color get textMain => textPrimary;
  Color get textSec => textSecondary;
  Color get textLight => textMuted;
  Color get ctaBg => cta;
  Color get ctaFg => onCta;
  Color get successFg => onSuccess;
  Color get dangerFg => onDanger;
  Color get warningFg => onWarning;
  Color get infoFg => onInfo;

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
    bg: Color(0xFFF4F6FB),
    surface: Color(0xFFFFFFFF),
    surfaceElevated: Color(0xFFF1F3F8),
    surfaceCard: Color(0xFFFFFFFF),
    surfaceMuted: Color(0xFFECEFF6),
    primary: Color(0xFF021B79),
    onPrimary: Color(0xFFFFFFFF),
    cta: Color(0xFF0340A5),
    onCta: Color(0xFFFFFFFF),
    ctaSoft: Color(0xFFEAF2FF),
    accent: Color(0xFFFBC926),
    income: Color(0xFF16A34A),
    expense: Color(0xFFDC2626),
    success: Color(0xFF16A34A),
    warning: Color(0xFFD97706),
    danger: Color(0xFFDC2626),
    info: Color(0xFF2563EB),
    neutral: Color(0xFF667085),
    disabled: Color(0xFFD8DDE8),
    disabledFg: Color(0xFF8B94A7),
    border: Color(0xFFDDE2EC),
    divider: Color(0xFFE8EBF2),
    textPrimary: Color(0xFF111827),
    textSecondary: Color(0xFF4B5563),
    textMuted: Color(0xFF7C879A),
    onSurface: Color(0xFF111827),
    onSurfaceMuted: Color(0xFF4B5563),
    successBg: Color(0xFFE8F8EE),
    dangerBg: Color(0xFFFDECEC),
    warningBg: Color(0xFFFFF3D8),
    infoBg: Color(0xFFEAF1FF),
    onSuccess: Color(0xFFFFFFFF),
    onDanger: Color(0xFFFFFFFF),
    onWarning: Color(0xFF111827),
    onInfo: Color(0xFFFFFFFF),
    gradA: Color(0xFF55ABFF),
    gradB: Color(0xFF021B79),
  );

  // ===== Dark Mode (true-black "Calm Capital" identity) =====
  // Canvas is true black to match MaliTokens.dark.canvas / MaliScreen, so the
  // flagship screens and the ambient scaffold are seamless. Semantics use the
  // brighter dark-on-black variants (income/expense/warning) that read on black.
  static const AppColors dark = AppColors(
    bg: Color(0xFF000000),
    surface: Color(0xFF121317),
    surfaceElevated: Color(0xFF181A20),
    surfaceCard: Color(0xFF121317),
    surfaceMuted: Color(0xFF0C0D11),
    primary: Color(0xFF9DB9FF),
    onPrimary: Color(0xFF00123A),
    cta: Color(0xFF2E6BFF),
    onCta: Color(0xFFFFFFFF),
    ctaSoft: Color(0xFF15233F),
    accent: Color(0xFFFBC926),
    income: Color(0xFF22C55E),
    expense: Color(0xFFEF4444),
    success: Color(0xFF22C55E),
    warning: Color(0xFFF59E0B),
    danger: Color(0xFFEF4444),
    info: Color(0xFF3B82F6),
    neutral: Color(0xFF9AA3B2),
    disabled: Color(0xFF262A32),
    disabledFg: Color(0xFF6B7280),
    border: Color(0xFF23262E),
    divider: Color(0xFF1A1D23),
    textPrimary: Color(0xFFFFFFFF),
    textSecondary: Color(0xFFA8AEBA),
    textMuted: Color(0xFF6E7683),
    onSurface: Color(0xFFFFFFFF),
    onSurfaceMuted: Color(0xFFA8AEBA),
    successBg: Color(0xFF0E2A18),
    dangerBg: Color(0xFF2A1113),
    warningBg: Color(0xFF2A1F0A),
    infoBg: Color(0xFF0E1D33),
    onSuccess: Color(0xFFFFFFFF),
    onDanger: Color(0xFFFFFFFF),
    onWarning: Color(0xFF111827),
    onInfo: Color(0xFFFFFFFF),
    gradA: Color(0xFF2E6BFF),
    gradB: Color(0xFF5B4FE0),
  );

  @override
  AppColors copyWith({
    Color? bg,
    Color? surface,
    Color? surfaceElevated,
    Color? surfaceCard,
    Color? surfaceMuted,
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
    Color? disabledFg,
    Color? border,
    Color? divider,
    Color? textPrimary,
    Color? textSecondary,
    Color? textMuted,
    Color? onSurface,
    Color? onSurfaceMuted,
    Color? successBg,
    Color? dangerBg,
    Color? warningBg,
    Color? infoBg,
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
      surfaceCard: surfaceCard ?? this.surfaceCard,
      surfaceMuted: surfaceMuted ?? this.surfaceMuted,
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
      disabledFg: disabledFg ?? this.disabledFg,
      border: border ?? this.border,
      divider: divider ?? this.divider,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textMuted: textMuted ?? this.textMuted,
      onSurface: onSurface ?? this.onSurface,
      onSurfaceMuted: onSurfaceMuted ?? this.onSurfaceMuted,
      successBg: successBg ?? this.successBg,
      dangerBg: dangerBg ?? this.dangerBg,
      warningBg: warningBg ?? this.warningBg,
      infoBg: infoBg ?? this.infoBg,
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
      surfaceCard: Color.lerp(surfaceCard, other.surfaceCard, t)!,
      surfaceMuted: Color.lerp(surfaceMuted, other.surfaceMuted, t)!,
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
      disabledFg: Color.lerp(disabledFg, other.disabledFg, t)!,
      border: Color.lerp(border, other.border, t)!,
      divider: Color.lerp(divider, other.divider, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
      onSurface: Color.lerp(onSurface, other.onSurface, t)!,
      onSurfaceMuted: Color.lerp(onSurfaceMuted, other.onSurfaceMuted, t)!,
      successBg: Color.lerp(successBg, other.successBg, t)!,
      dangerBg: Color.lerp(dangerBg, other.dangerBg, t)!,
      warningBg: Color.lerp(warningBg, other.warningBg, t)!,
      infoBg: Color.lerp(infoBg, other.infoBg, t)!,
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
