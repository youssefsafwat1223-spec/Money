import 'package:flutter/material.dart';

/// AppShadows — Centralized, subtle, premium shadow system.
class AppShadows {
  AppShadows._();

  /// card - Subtle drop shadow for resting cards in light mode.
  static const List<BoxShadow> card = [
    BoxShadow(
      color: Color(0x0A000000), // 4% opacity black equivalent
      blurRadius: 8,
      offset: Offset(0, 2),
    ),
  ];

  /// float - Deeper shadow for floating elements (sheets, popups).
  static const List<BoxShadow> float = [
    BoxShadow(
      color: Color(0x14000000), // 8% opacity black
      blurRadius: 20,
      offset: Offset(0, 8),
    ),
  ];

  /// nav - Floating navigation shadow.
  static const List<BoxShadow> nav = [
    BoxShadow(
      color: Color(0x0D000000), // 5% opacity
      blurRadius: 30,
      offset: Offset(0, 10),
    ),
  ];

  /// cta - Accent glow for primary buttons.
  /// NOTE: This currently uses a hardcoded Mali Blue with 20% opacity.
  /// In Phase 2 components, this should be generated dynamically via `colors.cta.withValues(...)` 
  /// so it correctly tracks dark/light mode accent color.
  static const List<BoxShadow> cta = [
    BoxShadow(
      color: Color(0x33006B8F), // Fixed Mali Blue for now (legacy compat)
      blurRadius: 10,
      offset: Offset(0, 4),
    ),
  ];
}
