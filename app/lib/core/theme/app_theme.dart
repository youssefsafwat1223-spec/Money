import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'app_typography.dart';

/// يبني [ThemeData] للوضعين بالاعتماد على [AppColors] و[AppTypography].
class AppTheme {
  AppTheme._();

  static ThemeData light = _build(AppColors.light, Brightness.light);
  static ThemeData dark = _build(AppColors.dark, Brightness.dark);

  static ThemeData _build(AppColors c, Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: c.primary,
      brightness: brightness,
    ).copyWith(
      surface: c.surface,
      error: c.danger,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      scaffoldBackgroundColor: c.bg,
      colorScheme: scheme,
      textTheme: AppTypography.textTheme(c.textMain),
      extensions: <ThemeExtension<dynamic>>[c],
      splashFactory: NoSplash.splashFactory,
      cardTheme: CardThemeData(
        color: c.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: c.primary,
          foregroundColor: brightness == Brightness.dark ? Colors.black : Colors.white,
          elevation: 0,
          shape: const StadiumBorder(),
          minimumSize: const Size(double.infinity, 56),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: c.primary,
          side: BorderSide(color: c.border, width: 1.5),
          shape: const StadiumBorder(),
          minimumSize: const Size(double.infinity, 56),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }
}
