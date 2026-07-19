import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// الطباعة — Arabic-first premium typography for Qirsh.
class AppTypography {
  AppTypography._();

  static const List<FontFeature> _tabular = [FontFeature.tabularFigures()];

  /// Canonical app text style. IBM Plex Sans Arabic supplies the Arabic
  /// glyphs; IBM Plex Sans is the matching Latin companion for mixed strings.
  static TextStyle custom({
    required double size,
    required FontWeight weight,
    required double height,
    double letterSpacing = 0,
    bool tabular = false,
    Color? color,
    List<Shadow>? shadows,
  }) {
    return GoogleFonts.ibmPlexSansArabic(
      fontSize: size,
      fontWeight: weight,
      height: height,
      letterSpacing: letterSpacing,
      color: color,
      shadows: shadows,
      fontFeatures: tabular ? _tabular : null,
    ).copyWith(
      fontFamilyFallback: [
        GoogleFonts.ibmPlexSans().fontFamily!,
      ],
    );
  }

  // ===== Premium Named Styles =====

  static TextStyle amountHero(Color c) => custom(
      size: 40, weight: FontWeight.w800, height: 1.10, tabular: true, color: c);

  static TextStyle amountMedium(Color c) => custom(
      size: 24, weight: FontWeight.w700, height: 1.20, tabular: true, color: c);

  static TextStyle amountSmall(Color c) => custom(
      size: 18, weight: FontWeight.w600, height: 1.25, tabular: true, color: c);

  static TextStyle display(Color c) =>
      custom(size: 32, weight: FontWeight.w800, height: 1.06, color: c);

  static TextStyle title1(Color c) =>
      custom(size: 24, weight: FontWeight.w700, height: 1.18, color: c);

  static TextStyle title2(Color c) =>
      custom(size: 20, weight: FontWeight.w700, height: 1.24, color: c);

  static TextStyle headline(Color c) =>
      custom(size: 18, weight: FontWeight.w700, height: 1.30, color: c);

  static TextStyle title(Color c) =>
      custom(size: 16, weight: FontWeight.w600, height: 1.40, color: c);

  static TextStyle body(Color c) =>
      custom(size: 16, weight: FontWeight.w400, height: 1.50, color: c);

  static TextStyle bodyStrong(Color c) =>
      custom(size: 16, weight: FontWeight.w600, height: 1.50, color: c);

  static TextStyle callout(Color c) =>
      custom(size: 15, weight: FontWeight.w400, height: 1.46, color: c);

  static TextStyle subhead(Color c) =>
      custom(size: 14, weight: FontWeight.w600, height: 1.43, color: c);

  static TextStyle footnote(Color c) =>
      custom(size: 13, weight: FontWeight.w400, height: 1.38, color: c);

  static TextStyle caption(Color c) =>
      custom(size: 12, weight: FontWeight.w500, height: 1.33, color: c);

  static TextStyle label(Color c) =>
      custom(size: 12, weight: FontWeight.w600, height: 1.25, color: c);

  static TextStyle micro(Color c) =>
      custom(size: 11, weight: FontWeight.w500, height: 1.30, color: c);

  /// يبني [TextTheme] كامل بلون النص الأساسي.
  static TextTheme textTheme(Color main) => TextTheme(
        displayLarge: display(main),
        displayMedium: custom(
          size: 28,
          weight: FontWeight.w700,
          height: 1.08,
          color: main,
        ),
        displaySmall: custom(
          size: 24,
          weight: FontWeight.w700,
          height: 1.08,
          color: main,
        ),
        headlineLarge: title1(main),
        headlineMedium: title2(main),
        headlineSmall: headline(main),
        titleLarge: headline(main),
        titleMedium: title(main),
        titleSmall: subhead(main),
        bodyLarge: body(main),
        bodyMedium: callout(main),
        bodySmall: footnote(main),
        labelLarge: subhead(main),
        labelMedium: label(main),
        labelSmall: micro(main),
      );
}
