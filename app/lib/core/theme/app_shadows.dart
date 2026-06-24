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

  /// ctaGlow - Very restrained violet presence for primary actions only.
  static const List<BoxShadow> ctaGlow = [
    BoxShadow(
      color: Color(0x246C5CFF),
      blurRadius: 18,
      offset: Offset(0, 8),
    ),
  ];

  // Legacy aliases
  static const List<BoxShadow> float = elevatedCard;
  static const List<BoxShadow> nav = floatingNav;
  static const List<BoxShadow> cta = ctaGlow;
}
