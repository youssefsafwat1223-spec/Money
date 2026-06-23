import 'package:flutter/material.dart';

/// AppGradients — Centralized, purpose-driven gradient system.
class AppGradients {
  AppGradients._();

  /// Brand hero gradient (used in headers and prominent branding).
  /// Safe for both light and dark mode as a bold backdrop.
  static const LinearGradient brandHero = LinearGradient(
    colors: [
      Color(0xFF0C0D11),
      Color(0xFF141623),
      Color(0xFF06131C),
    ],
    begin: Alignment.topRight,
    end: Alignment.bottomLeft,
  );

  /// Wallet card gradient (subtle dark premium feel).
  static const LinearGradient walletCard = LinearGradient(
    colors: [
      Color(0xFF141623),
      Color(0xFF0C2450),
    ],
    begin: Alignment.topRight,
    end: Alignment.bottomLeft,
  );

  /// AI subtle presence gradient (electric blue signature transition).
  static const LinearGradient aiSubtle = LinearGradient(
    colors: [
      Color(0xFF5488FE),
      Color(0xFF238AFF),
    ],
    begin: Alignment.topRight,
    end: Alignment.bottomLeft,
  );

  // ===== Legacy references for Phase 1 backward compatibility =====
  static const LinearGradient heroHeader = brandHero;
  static const LinearGradient ctaBlue = aiSubtle;
  static const LinearGradient darkSurface = walletCard;
  static const LinearGradient aiPremium = aiSubtle;
}
