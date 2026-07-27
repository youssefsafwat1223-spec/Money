import 'package:flutter/material.dart';

/// يحتوي على مسارات جميع الأصول (Assets) المستخدمة في التطبيق.
class AppAssets {
  AppAssets._();

  /// مسار شعار التطبيق للمظهر الفاتح (Light Mode)
  static const String logoLight = 'assets/logo/logo_light.png';

  /// مسار شعار التطبيق للمظهر الداكن (Dark Mode)
  static const String logoDark = 'assets/logo/logo_dark.png';

  /// العملة الزرقاء — للـ light mode
  static const String qirshCoin = 'assets/qirsh/qirsh_coin.png';

  /// العملة الذهبية — للـ dark mode
  static const String qirshCoinGold = 'assets/qirsh/qirsh_coin_gold.png';

  static const String qirshLogoFull = 'assets/qirsh/qirsh_logo_full.png';
  static const String qirshLogoTagline = 'assets/qirsh/qirsh_logo_tagline.png';

  /// الشعار الذهبي مع الـ slogan (أبيض) — لـ dark mode
  static const String qirshLogoTaglineGold =
      'assets/qirsh/qirsh_logo_tagline_gold.png';

  /// بانرات الـ Onboarding
  static const String bannerOnboarding1 =
      'assets/qirsh/banner_onboarding_1.jpg';
  static const String bannerOnboarding2 =
      'assets/qirsh/banner_onboarding_2.jpg';

  /// قصاصة شفافة لليد والعملة الذهبية — تظهر فوق الخلفية الكحلية في صفحة الوعد
  static const String handCoinCutout = 'assets/qirsh/hand_coin_cutout.png';

  /// صورة البطل لشاشة تسجيل الدخول — اليد والبرطمان مقصوصة لتذوب في الكحلي
  static const String authHero = 'assets/qirsh/auth_hero.jpg';

  /// العملة المناسبة حسب الثيم (زرقاء light / ذهبية dark)
  static String getCoin(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return brightness == Brightness.dark ? qirshCoinGold : qirshCoin;
  }

  /// الشعار مع الـ slogan حسب الثيم
  static String getLogoTagline(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return brightness == Brightness.dark
        ? qirshLogoTaglineGold
        : qirshLogoTagline;
  }

  static String getLogo(BuildContext context) => qirshLogoFull;
}
