/// AppSpacing — 4pt base spacing system.
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
  static const double pagePadding = 24;
  static const double sectionGap = 32;
  static const double listGap = 16;
  static const double cardPadding = 20;
  static const double chipPadding = 12;
  static const double buttonHeight = 56;
  static const double sheetPadding = 24;

  // Legacy alias
  static const double gutter = pagePadding;
}

/// AppRadius — Standardized border radii.
class AppRadius {
  AppRadius._();

  // Semantic radius
  static const double sm = 8;
  static const double md = 16;
  static const double lg = 24;
  static const double pill = 999;
  static const double full = 9999;

  // Explicit semantic tokens
  static const double small = sm;
  static const double medium = md;
  static const double large = lg;
  static const double xlarge = 32;

  static const double card = 24;
  static const double cardLg = 32;
  static const double button = 16;
  static const double nav = 28;
}
