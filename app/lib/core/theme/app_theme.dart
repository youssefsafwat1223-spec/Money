import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'app_spacing.dart';
import 'app_typography.dart';

/// يبني [ThemeData] للوضعين بالاعتماد على [AppColors] و[AppTypography].
class AppTheme {
  AppTheme._();

  static ThemeData light = _build(AppColors.light, Brightness.light);

  /// True-black "Calm Capital" dark theme. Every screen that reads
  /// `context.colors` picks this up automatically; the flagship primitives
  /// ([MaliScreen] etc.) resolve their own dark tokens via [MaliTokens.of].
  static ThemeData dark = _build(AppColors.dark, Brightness.dark);

  /// Shared navy palette for every modal sheet and the database recovery UI.
  static const AppColors sheetColors = AppColors(
    bg: Color(0xFF021B79),
    surface: Color(0xFF021B79),
    surfaceElevated: Color(0xFF0F2E96),
    surfaceCard: Color(0xFF0F2E96),
    surfaceMuted: Color(0xFF173A9E),
    primary: Color(0xFF8DBBFF),
    onPrimary: Color(0xFFFFFFFF),
    cta: Color(0xFF3B82F6),
    onCta: Color(0xFFFFFFFF),
    ctaSoft: Color(0xFF102B52),
    accent: Color(0xFFFBC926),
    income: Color(0xFF22C55E),
    expense: Color(0xFFEF4444),
    success: Color(0xFF34D399),
    warning: Color(0xFFF59E0B),
    danger: Color(0xFFF87171),
    info: Color(0xFF60A5FA),
    neutral: Color(0xFF7F8EA3),
    disabled: Color(0xFF172238),
    disabledFg: Color(0xFF64748B),
    border: Color(0xFF243553),
    divider: Color(0xFF172844),
    textPrimary: Color(0xFFF4F7FC),
    textSecondary: Color(0xFFB5C2D6),
    textMuted: Color(0xFF8190A8),
    onSurface: Color(0xFFF4F7FC),
    onSurfaceMuted: Color(0xFFB5C2D6),
    successBg: Color(0xFF0D2B1D),
    dangerBg: Color(0xFF2B1515),
    warningBg: Color(0xFF2B1E00),
    infoBg: Color(0xFF102B52),
    onSuccess: Color(0xFF000000),
    onDanger: Color(0xFFFFFFFF),
    onWarning: Color(0xFF000000),
    onInfo: Color(0xFFFFFFFF),
    gradA: Color(0xFF2563EB),
    gradB: Color(0xFF061A40),
  );
  static final ThemeData sheet = _build(sheetColors, Brightness.dark);

  /// Bottom-sheet surface per the design mockups: charcoal in dark, white in
  /// light (mali_pages.html `--sheet-bg`). Shared by [_build]'s
  /// [BottomSheetThemeData] and [AppSheetScaffold] so every sheet matches.
  static const Color sheetSurfaceDark = Color(0xFF14161C);
  static const Color sheetSurfaceLight = Color(0xFFFFFFFF);
  static Color sheetSurfaceFor(Brightness b) =>
      b == Brightness.dark ? sheetSurfaceDark : sheetSurfaceLight;

  static ThemeData _build(AppColors c, Brightness brightness) {
    final sheetSurface = sheetSurfaceFor(brightness);
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
        backgroundColor: sheetSurface,
        modalBackgroundColor: sheetSurface,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        dragHandleColor: c.textSecondary,
        clipBehavior: Clip.antiAlias,
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
        labelStyle: AppTypography.body(c.textMuted),
        hintStyle: AppTypography.body(c.textMuted.withValues(alpha: 0.6)),
        prefixIconColor: c.textMuted,
        suffixIconColor: c.textMuted,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: AppSpacing.s4, vertical: 12),
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
