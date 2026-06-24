import 'package:flutter/material.dart';

/// AppGradients — Centralized, purpose-driven gradient system.
class AppGradients {
  AppGradients._();

  /// Brand hero gradient (used in headers and prominent branding).
  /// Safe for both light and dark mode as a bold backdrop.
  static const LinearGradient brandHero = LinearGradient(
    colors: [
      Color(0xFF0C0D11),
      Color(0xFF17182A),
      Color(0xFF2A235E),
    ],
    begin: Alignment.topRight,
    end: Alignment.bottomLeft,
  );

  /// Primary CTA gradient. Use only for prominent, intentional action moments.
  static const LinearGradient primaryCta = LinearGradient(
    colors: [
      Color(0xFF8D7CFF),
      Color(0xFF6C5CFF),
      Color(0xFF4B3EE6),
    ],
    begin: Alignment.topRight,
    end: Alignment.bottomLeft,
  );

  /// Quiet card/sheet gradient for depth without blur-heavy effects.
  static const LinearGradient subtleSurface = LinearGradient(
    colors: [
      Color(0xFF1D1F28),
      Color(0xFF15161C),
    ],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );

  /// Illustration accent gradient for Mali's abstract finance visuals.
  static const LinearGradient accentIllustration = LinearGradient(
    colors: [
      Color(0xFFF472B6),
      Color(0xFF8D7CFF),
      Color(0xFF3B82F6),
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
