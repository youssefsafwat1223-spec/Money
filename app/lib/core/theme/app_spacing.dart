/// AppSpacing — 8pt-inspired spacing system with 4pt micro steps.
class AppSpacing {
  AppSpacing._();

  static const double s1 = 4;
  static const double s2 = 8;
  static const double s3 = 12;
  static const double s4 = 16;
  static const double s5 = 20;
  static const double s6 = 24;
  static const double s7 = 32;
  static const double s8 = 40;
  static const double s9 = 48;
  static const double s10 = 64;

  // Semantic spacing
  static const double pagePadding = s6;
  static const double pagePaddingCompact = s4;
  static const double sectionGap = s7;
  static const double sectionGapCompact = s5;
  static const double listGap = s3;
  static const double cardPadding = 20;
  static const double cardPaddingLarge = s6;
  static const double chipPadding = s3;
  static const double chipGap = s2;
  static const double fieldGap = s4;
  static const double iconGap = s3;
  static const double buttonGap = s3;
  static const double buttonHeight = 56;
  static const double buttonHeightCompact = 48;
  static const double sheetPadding = s6;
  static const double sheetTopGap = s4;

  // Legacy aliases
  static const double gutter = pagePadding;
  static const double screenPadding = pagePadding;
}

/// AppRadius — Standardized border radii.
class AppRadius {
  AppRadius._();

  // Semantic radius
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 28;
  static const double pill = 999;
  static const double full = 9999;

  // Explicit semantic tokens
  static const double extraSmall = xs;
  static const double small = sm;
  static const double medium = md;
  static const double large = lg;
  static const double xlarge = xl;

  static const double card = xl;
  static const double cardLg = xxl;
  static const double sheet = xxl;
  static const double button = lg;
  static const double chip = pill;
  static const double nav = xxl;
}
