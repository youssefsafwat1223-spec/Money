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

  // Semantic spacing — Compact UI system (docs/MALI_COMPACT_UI_SYSTEM_PLAN.md).
  // Evolved toward ~25–35% less vertical whitespace; every screen inherits these.
  static const double pagePadding = s5; // 20 (was 24)
  static const double pagePaddingCompact = s4; // 16
  static const double sectionGap = s6; // 24 (was 32)
  static const double sectionGapCompact = s4; // 16 (was 20)
  static const double listGap = s3; // 12
  static const double cardPadding = 16; // (was 20)
  static const double cardPaddingCompact = 14; // simple/short cards
  static const double cardPaddingLarge = s5; // 20 (was 24)
  static const double chipPadding = s3;
  static const double chipGap = s2;
  static const double fieldGap = s3; // 12 (was 16)
  static const double iconGap = s3;
  static const double buttonGap = s3;
  static const double buttonHeight = 50; // (was 56) — ≥ 48 accessible
  static const double buttonHeightCompact = 46; // (was 48) — ≥ 44 accessible
  static const double sheetPadding = s5; // 20 (was 24)
  static const double sheetTopGap = s3; // 12 (was 16)

  // Component density tokens (Compact UI system).
  static const double headerTopInset = 44; // CalmPageHeader top (was 64)
  static const double rowPaddingV = 11; // list-row vertical padding (≈ 58–62px row)
  static const double navBarHeight = 54; // glass nav (was 62)

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
  // Mali flagship system (docs/MALI_DESIGN_SYSTEM.md) — flagship surfaces
  // (hero, top-level MaliCard) that want a more generous, calmer curve.
  static const double xxxl = 32;
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
