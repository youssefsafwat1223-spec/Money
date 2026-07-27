import 'package:flutter/material.dart';

/// AppShadows — Centralized, subtle, premium shadow system.
class AppShadows {
  AppShadows._();

  /// card - Subtle drop shadow for resting cards in light mode.
  static const List<BoxShadow> card = [
    BoxShadow(
      color: Color(0x0F101828),
      blurRadius: 14,
      offset: Offset(0, 2),
    ),
  ];

  /// elevatedCard - Premium card lift for summary panels and selected states.
  static const List<BoxShadow> elevatedCard = [
    BoxShadow(
      color: Color(0x14101828),
      blurRadius: 24,
      offset: Offset(0, 10),
    ),
  ];

  /// sheet - Controlled depth for modal and bottom-sheet surfaces.
  static const List<BoxShadow> sheet = [
    BoxShadow(
      color: Color(0x29101828),
      blurRadius: 34,
      offset: Offset(0, -10),
    ),
  ];

  /// floatingNav - Soft lift for persistent navigation surfaces.
  static const List<BoxShadow> floatingNav = [
    BoxShadow(
      color: Color(0x1A101828),
      blurRadius: 28,
      offset: Offset(0, 12),
    ),
  ];

  /// ctaGlow - Gold glow for primary actions.
  static const List<BoxShadow> ctaGlow = [
    BoxShadow(
      color: Color(0x44FBC926),
      blurRadius: 18,
      offset: Offset(0, 8),
    ),
  ];

  // Legacy aliases
  static const List<BoxShadow> float = elevatedCard;
  static const List<BoxShadow> nav = floatingNav;
  static const List<BoxShadow> cta = ctaGlow;

  // ===== Mali flagship system (docs/MALI_DESIGN_SYSTEM.md) =====
  // Additive only — nothing above is modified or retired.

  /// floatSoft - Ambient grounding for a surface floating on a dark canvas.
  /// Two-layer: a soft key shadow plus a faint wide ambient falloff, so depth
  /// reads without a harsh edge.
  static const List<BoxShadow> floatSoft = [
    BoxShadow(
      color: Color(0x33000000),
      blurRadius: 28,
      offset: Offset(0, 8),
    ),
    BoxShadow(
      color: Color(0x14000000),
      blurRadius: 48,
      offset: Offset(0, 20),
    ),
  ];

  /// heroGlow - Restrained colored glow for the small set of flagship accent
  /// surfaces (AI insight, selected states). Never applied to the balance
  /// hero itself, which stays directly on canvas — see design doc §0.
  static const List<BoxShadow> heroGlow = [
    BoxShadow(
      color: Color(0x4D2E6BFF), // accent @ 30% — mockup --hero-glow
      blurRadius: 48,
      offset: Offset(0, 16),
    ),
  ];
}
