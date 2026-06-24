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
      secondary: c.accent,
      onSecondary: c.onCta,
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
        color: c.surfaceCard,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.card),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: c.divider,
        thickness: 1,
        space: 1,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: c.surfaceElevated,
        modalBackgroundColor: c.surfaceElevated,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        dragHandleColor: c.border,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppRadius.sheet),
          ),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: c.cta,
        linearTrackColor: c.surfaceMuted,
        circularTrackColor: c.surfaceMuted,
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
          textStyle: AppTypography.title(c.onCta),
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
              return c.disabledFg;
            }
            return c.onCta;
          }),
          minimumSize: const WidgetStatePropertyAll(
              Size(double.infinity, AppSpacing.buttonHeight)),
          textStyle: WidgetStatePropertyAll(AppTypography.title(c.onCta)),
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
          textStyle: AppTypography.title(c.cta),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: c.surfaceMuted,
        selectedColor: c.ctaSoft,
        disabledColor: c.disabled,
        labelStyle: AppTypography.caption(c.textSecondary),
        secondaryLabelStyle: AppTypography.caption(c.cta),
        side: BorderSide(color: c.border),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.chip),
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
        fillColor: c.surfaceMuted.withValues(
          alpha: brightness == Brightness.dark ? 0.72 : 0.86,
        ),
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
