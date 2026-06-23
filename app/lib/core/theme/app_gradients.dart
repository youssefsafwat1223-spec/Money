import 'package:flutter/material.dart';

/// AppGradients — Centralized, purpose-driven gradient system.
class AppGradients {
  AppGradients._();

  /// Brand hero gradient (used in headers and prominent branding).
  /// Safe for both light and dark mode as a bold backdrop.
  static const LinearGradient brandHero = LinearGradient(
    colors: [
      Color(0xFF062635),
      Color(0xFF073B50),
      Color(0xFF01070C),
    ],
    begin: Alignment.topRight,
    end: Alignment.bottomLeft,
  );

  /// Wallet card gradient (subtle dark premium feel).
  static const LinearGradient walletCard = LinearGradient(
    colors: [Color(0xFF06131C), Color(0xFF073B50)],
    begin: Alignment.topRight,
    end: Alignment.bottomLeft,
  );

  /// AI subtle presence gradient (purple/teal mix).
  static const LinearGradient aiSubtle = LinearGradient(
    colors: [Color(0xFF4DA3C7), Color(0xFF006B8F)],
    begin: Alignment.topRight,
    end: Alignment.bottomLeft,
  );

  // ===== Legacy references for Phase 1 backward compatibility =====
  static const LinearGradient heroHeader = brandHero;
  static const LinearGradient ctaBlue = aiSubtle;
  static const LinearGradient darkSurface = walletCard;
  static const LinearGradient aiPremium = aiSubtle;
}
