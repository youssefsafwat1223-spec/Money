import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'app_spacing.dart';
import 'app_typography.dart';

/// يبني [ThemeData] للوضعين بالاعتماد على [AppColors] و[AppTypography].
class AppTheme {
  AppTheme._();

  static ThemeData light = _build(AppColors.light, Brightness.light);
  static ThemeData dark = _build(AppColors.dark, Brightness.dark);

  static ThemeData _build(AppColors c, Brightness brightness) {
    // Seed the Material colour scheme from the CTA colour (interactive blue),
    // not from c.primary (navy/white brand text). This keeps Material widgets
    // (chips, switches, progress indicators) in the blue family rather than
    // generating a navy-tinted palette.
    final scheme = ColorScheme.fromSeed(
      seedColor: c.cta,
      brightness: brightness,
    ).copyWith(
      surface: c.surface,
      primary: c.cta,
      onPrimary: c.onCta,
      error: c.danger,
      onError: Colors.white,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      scaffoldBackgroundColor: c.bg,
      colorScheme: scheme,
      textTheme: AppTypography.textTheme(c.textPrimary),
      extensions: <ThemeExtension<dynamic>>[c],
      splashFactory: NoSplash.splashFactory,
      cardTheme: CardThemeData(
        color: c.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.card),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: c.cta,
          foregroundColor: c.onCta,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.button),
          ),
          minimumSize: const Size(double.infinity, AppSpacing.buttonHeight),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.disabled)) {
              return c.disabled;
            }
            return c.cta;
          }),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.disabled)) {
              return c.textMuted;
            }
            return c.onCta;
          }),
          minimumSize: const WidgetStatePropertyAll(Size(double.infinity, AppSpacing.buttonHeight)),
          textStyle: const WidgetStatePropertyAll(
            TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.button),
            ),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: c.cta,
          side: BorderSide(color: c.border, width: 1.5),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.button),
          ),
          minimumSize: const Size(double.infinity, AppSpacing.buttonHeight),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: c.bg,
        foregroundColor: c.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: AppTypography.title2(c.textPrimary).copyWith(
          fontWeight: FontWeight.w700,
          fontSize: 18,
        ),
        iconTheme: IconThemeData(color: c.cta),
        actionsIconTheme: IconThemeData(color: c.cta),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: brightness == Brightness.dark
            ? c.surfaceElevated.withValues(alpha: 0.45)
            : c.surfaceElevated.withValues(alpha: 0.55),
        labelStyle: TextStyle(color: c.textMuted),
        hintStyle: TextStyle(color: c.textMuted.withValues(alpha: 0.6)),
        prefixIconColor: c.textMuted,
        suffixIconColor: c.textMuted,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: AppSpacing.s4, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: BorderSide(color: c.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: BorderSide(color: c.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: BorderSide(color: c.cta, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: BorderSide(color: c.danger),
        ),
      ),
    );
  }
}
