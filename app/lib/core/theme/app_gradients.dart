import 'package:flutter/material.dart';

/// AppGradients — Centralized, purpose-driven gradient system.
class AppGradients {
  AppGradients._();

  /// Brand hero gradient (used in headers and prominent branding).
  /// Safe for both light and dark mode as a bold backdrop.
  static const LinearGradient brandHero = LinearGradient(
    colors: [
      Color(0xFF021B79),
      Color(0xFF0340A5),
      Color(0xFF55ABFF),
    ],
    begin: Alignment.topRight,
    end: Alignment.bottomLeft,
  );

  /// Primary CTA gradient. Use only for prominent, intentional action moments.
  static const LinearGradient primaryCta = LinearGradient(
    colors: [
      Color(0xFF55ABFF),
      Color(0xFF0340A5),
      Color(0xFF021B79),
    ],
    begin: Alignment.topRight,
    end: Alignment.bottomLeft,
  );

  /// Quiet card/sheet gradient for depth without blur-heavy effects.
  static const LinearGradient subtleSurface = LinearGradient(
    colors: [
      Color(0xFF162646),
      Color(0xFF0B1224),
    ],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );

  /// Illustration accent gradient for Qirsh's abstract finance visuals.
  static const LinearGradient accentIllustration = LinearGradient(
    colors: [
      Color(0xFFFBC926),
      Color(0xFFC3922D),
      Color(0xFF0340A5),
    ],
    begin: Alignment.topRight,
    end: Alignment.bottomLeft,
  );

  /// Controlled danger gradient for rare warning states.
  static const LinearGradient danger = LinearGradient(
    colors: [
      Color(0xFFEF4444),
      Color(0xFFDB2777),
    ],
    begin: Alignment.topRight,
    end: Alignment.bottomLeft,
  );

  // ===== Legacy references for Phase 1 backward compatibility =====
  static const LinearGradient heroHeader = brandHero;
  static const LinearGradient walletCard = subtleSurface;
  static const LinearGradient aiSubtle = accentIllustration;
  static const LinearGradient ctaBlue = primaryCta;
  static const LinearGradient darkSurface = subtleSurface;
  static const LinearGradient aiPremium = accentIllustration;
}
