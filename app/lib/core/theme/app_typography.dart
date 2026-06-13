import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// الطباعة — Premium Minimalist (Inter + IBM Plex Sans Arabic).
class AppTypography {
  AppTypography._();

  static const List<FontFeature> _tabular = [FontFeature.tabularFigures()];

  // Helper for applying dual-font setup. 
  // Inter handles Latin, IBM Plex Sans Arabic handles Arabic naturally.
  static TextStyle _premiumText({
    required double size,
    required FontWeight weight,
    required double height,
    double letterSpacing = 0,
    bool tabular = false,
    Color? color,
  }) {
    // We use Inter as the primary font for English/Numbers
    // and fallback to IBM Plex Sans Arabic for Arabic text.
    return GoogleFonts.inter(
      fontSize: size,
      fontWeight: weight,
      height: height,
      letterSpacing: letterSpacing,
      color: color,
      fontFeatures: tabular ? _tabular : null,
    ).copyWith(
      fontFamilyFallback: [
        GoogleFonts.ibmPlexSansArabic().fontFamily!,
        GoogleFonts.alexandria().fontFamily!, // Emergency fallback
      ],
    );
  }

  // ===== Premium Named Styles =====
  
  // Tight letter spacing for large english numbers (-0.5).
  // Arabic text will use its native spacing as fallback or we avoid tight spacing globally.
  // Actually, to keep Arabic safe, we only use tight spacing on the hero amount which is usually numbers.
  static TextStyle amountHero(Color c) => _premiumText(
      size: 40,
      weight: FontWeight.w800,
      height: 1.10,
      letterSpacing: -0.5,
      tabular: true,
      color: c);
      
  static TextStyle display(Color c) => _premiumText(
      size: 32,
      weight: FontWeight.w800,
      height: 1.18,
      color: c);
      
  static TextStyle title1(Color c) => _premiumText(
      size: 24,
      weight: FontWeight.w700,
      height: 1.25,
      color: c);
      
  static TextStyle title2(Color c) => _premiumText(
      size: 20,
      weight: FontWeight.w600,
      height: 1.30,
      color: c);
      
  static TextStyle headline(Color c) => _premiumText(
      size: 18, 
      weight: FontWeight.w600, 
      height: 1.35, 
      color: c);
      
  static TextStyle body(Color c) => _premiumText(
      size: 16, 
      weight: FontWeight.w400, 
      height: 1.50, 
      color: c);
      
  static TextStyle bodyStrong(Color c) => _premiumText(
      size: 16, 
      weight: FontWeight.w600, 
      height: 1.50, 
      color: c);
      
  static TextStyle callout(Color c) => _premiumText(
      size: 15, 
      weight: FontWeight.w400, 
      height: 1.46, 
      color: c);
      
  static TextStyle subhead(Color c) => _premiumText(
      size: 14, 
      weight: FontWeight.w600, 
      height: 1.43, 
      color: c);
      
  static TextStyle footnote(Color c) => _premiumText(
      size: 13, 
      weight: FontWeight.w400, 
      height: 1.38, 
      color: c);
      
  static TextStyle caption(Color c) => _premiumText(
      size: 12, 
      weight: FontWeight.w600, 
      height: 1.33, 
      color: c);

  /// يبني [TextTheme] كامل بلون النص الأساسي.
  static TextTheme textTheme(Color main) => TextTheme(
        displayLarge: display(main),
        headlineLarge: title1(main),
        headlineMedium: title2(main),
        titleLarge: headline(main),
        bodyLarge: body(main),
        bodyMedium: callout(main),
        labelLarge: subhead(main),
        bodySmall: footnote(main),
        labelSmall: caption(main),
      );
}
