import 'dart:ui';

import 'package:flutter/material.dart';

/// الطباعة — Arabic-first premium typography for Qirsh.
class AppTypography {
  AppTypography._();

  static const List<FontFeature> _tabular = [FontFeature.tabularFigures()];

  /// The BUNDLED font family (pubspec `fonts:`) — no runtime GoogleFonts fetch,
  /// so the intended typography renders on the first offline launch.
  /// IBM Plex Sans Arabic (OFL) — واجهة أولاً: عربي ولاتيني متجانسين وأرقام
  /// واضحة. وهو نفس الخط اللي بيرسم بيه مولّد تقارير الـ PDF، فالتطبيق
  /// والتقرير المصدَّر بقوا بخط واحد.
  static const String fontFamily = 'IBMPlexSansArabic';

  /// Bundled fallbacks for whatever IBM Plex Sans Arabic lacks.
  static const List<String> _fontFallback = ['Vazirmatn', 'Alexandria'];

  /// Canonical app text style. **IBM Plex Sans Arabic** (bundled) supplies both
  /// the Arabic and Latin glyphs — it is [fontFamily], the approved family in
  /// `docs/design/BRAND_AND_DESIGN_SYSTEM.md` §7, and the same face the PDF report renderer
  /// draws with so export matches screen. Vazirmatn + Alexandria are the
  /// bundled fallbacks ([_fontFallback]).
  ///
  /// This comment previously said the reverse — that Vazirmatn was primary and
  /// IBM Plex a fallback — which contradicted the two constants directly above
  /// it and misled a reader into reporting the wrong family. Kept accurate
  /// deliberately: a comment that disagrees with its own file is worse than no
  /// comment.
  /// This is a plain [TextStyle] over the bundled family — identical size /
  /// weight / height / letter-spacing / colour / shadows / tabular figures as
  /// before, only the font source changed (runtime fetch → bundled).
  static TextStyle custom({
    required double size,
    required FontWeight weight,
    required double height,
    double letterSpacing = 0,
    bool tabular = false,
    Color? color,
    List<Shadow>? shadows,
  }) {
    return TextStyle(
      fontFamily: fontFamily,
      fontFamilyFallback: _fontFallback,
      fontSize: size,
      fontWeight: weight,
      height: height,
      letterSpacing: letterSpacing,
      color: color,
      shadows: shadows,
      fontFeatures: tabular ? _tabular : null,
    );
  }

  // ===== Premium Named Styles =====

  static TextStyle amountHero(Color c) => custom(
      size: 40, weight: FontWeight.w700, height: 1.10, tabular: true, color: c);

  static TextStyle amountMedium(Color c) => custom(
      size: 24, weight: FontWeight.w700, height: 1.20, tabular: true, color: c);

  static TextStyle amountSmall(Color c) => custom(
      size: 18, weight: FontWeight.w600, height: 1.25, tabular: true, color: c);

  // UX-002 — the scale below follows `docs/design/BRAND_AND_DESIGN_SYSTEM.md` §7 with ONE
  // deliberate deviation: sizes for Display / Title-1 / Title-2 are one step
  // SMALLER than the spec (32/24/20 rather than 34/28/22).
  //
  // That deviation predates Phase J and is kept, because the owner's density
  // brief asks for a more compact, professional feel and these are the styles
  // that dominate perceived bulk. Weights, however, had drifted HEAVIER than
  // the spec (w700 where it says SemiBold 600, w600 where it says Medium 500);
  // those are corrected here, which serves the spec and the density goal at the
  // same time — heavy type reads as large type.
  static TextStyle display(Color c) =>
      custom(size: 32, weight: FontWeight.w700, height: 1.06, color: c);

  static TextStyle title1(Color c) =>
      custom(size: 24, weight: FontWeight.w600, height: 1.18, color: c);

  static TextStyle title2(Color c) =>
      custom(size: 20, weight: FontWeight.w600, height: 1.24, color: c);

  static TextStyle headline(Color c) =>
      custom(size: 18, weight: FontWeight.w600, height: 1.30, color: c);

  static TextStyle title(Color c) =>
      custom(size: 16, weight: FontWeight.w600, height: 1.40, color: c);

  static TextStyle body(Color c) =>
      custom(size: 16, weight: FontWeight.w400, height: 1.50, color: c);

  static TextStyle bodyStrong(Color c) =>
      custom(size: 16, weight: FontWeight.w500, height: 1.50, color: c);

  static TextStyle callout(Color c) =>
      custom(size: 15, weight: FontWeight.w400, height: 1.46, color: c);

  static TextStyle subhead(Color c) =>
      custom(size: 14, weight: FontWeight.w500, height: 1.43, color: c);

  static TextStyle footnote(Color c) =>
      custom(size: 13, weight: FontWeight.w400, height: 1.38, color: c);

  static TextStyle caption(Color c) =>
      custom(size: 12, weight: FontWeight.w500, height: 1.33, color: c);

  static TextStyle label(Color c) =>
      custom(size: 12, weight: FontWeight.w600, height: 1.25, color: c);

  static TextStyle micro(Color c) =>
      custom(size: 11, weight: FontWeight.w500, height: 1.30, color: c);

  // ===== Mali flagship "calm" scale (docs/MALI_DESIGN_SYSTEM.md) =====
  // Additive only. The existing amountHero/display/w800 styles above are
  // untouched and remain in active use across the app — do not remove them.
  // These calm tokens cap weight at w600/w700 and tighten tracking on large
  // numbers, per the flagship spec. Adopted intentionally, screen by screen.

  /// The Home balance statement — large, calm, tight tracking, tabular.
  static TextStyle balanceHero(Color c) => custom(
      size: 52,
      weight: FontWeight.w600,
      height: 1.05,
      letterSpacing: -1.4,
      tabular: true,
      color: c);

  /// Calmer alternative to [display] — same role, capped at w600.
  static TextStyle calmDisplay(Color c) => custom(
      size: 32,
      weight: FontWeight.w600,
      height: 1.15,
      letterSpacing: -0.4,
      color: c);

  /// Calmer alternative to [title1]/section titles — capped at w600.
  static TextStyle calmTitle(Color c) =>
      custom(size: 22, weight: FontWeight.w600, height: 1.20, color: c);

  /// Compact section heading (docs/MALI_COMPACT_UI_SYSTEM_PLAN.md) — replaces
  /// oversized `headline`(18)/`title2`(20) misuse on section titles.
  static TextStyle sectionTitle(Color c) =>
      custom(size: 19, weight: FontWeight.w600, height: 1.25, color: c);

  /// Compact card / list-group title (also empty/error headings and default
  /// amount text). One step below a section title.
  static TextStyle cardTitle(Color c) =>
      custom(size: 16, weight: FontWeight.w600, height: 1.30, color: c);

  /// Plain-language verdict line for a RingProgress (e.g. "وضعك مستقر").
  /// Deliberately body-weight, not a headline — the ring carries the visual
  /// weight, the sentence explains it.
  static TextStyle verdict(Color c) =>
      custom(size: 17, weight: FontWeight.w500, height: 1.40, color: c);

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
