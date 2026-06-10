import 'package:flutter/material.dart';

/// يحتوي على مسارات جميع الأصول (Assets) المستخدمة في التطبيق.
class AppAssets {
  AppAssets._();

  /// مسار شعار التطبيق للمظهر الفاتح (Light Mode)
  static const String logoLight = 'assets/logo/logo_light.png';

  /// مسار شعار التطبيق للمظهر الداكن (Dark Mode)
  static const String logoDark = 'assets/logo/logo_dark.png';

  /// إرجاع الشعار المناسب بناءً على مظهر النظام أو التطبيق الحالي.
  static String getLogo(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return brightness == Brightness.dark ? logoDark : logoLight;
  }
}
