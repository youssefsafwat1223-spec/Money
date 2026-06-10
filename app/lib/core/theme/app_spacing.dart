/// سلّم المسافات (4pt base) والزوايا — من DESIGN_SYSTEM.md / BRAND_AND_DESIGN_SYSTEM.md.
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

  /// هامش الشاشة الجانبي القياسي.
  static const double gutter = 20;
}

/// زوايا الانحناء (Border Radius).
class AppRadius {
  AppRadius._();

  static const double sm = 8;
  static const double md = 16; // أزرار/حقول (Vibrant Fintech: 16)
  static const double lg = 18;
  static const double card = 24;
  static const double cardLg = 32; // الخزنة/البطاقات الكبيرة
  static const double pill = 999;
}
