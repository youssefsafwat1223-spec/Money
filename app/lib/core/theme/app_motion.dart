import 'package:flutter/material.dart';

/// AppMotion — Centralized motion durations and curves for Mali.
class AppMotion {
  AppMotion._();

  // Durations
  static const Duration fast = Duration(milliseconds: 120);
  static const Duration normal = Duration(milliseconds: 250);
  static const Duration slow = Duration(milliseconds: 380);
  static const Duration emphasized = Duration(milliseconds: 500);

  // Curves
  static const Curve standardCurve = Curves.easeOutCubic;
  static const Curve emphasizedCurve = Curves.easeInOutCubic;
  static const Curve sheetCurve = Curves.easeOutExpo;
  static const Curve cardRevealCurve = Curves.easeOutBack;

  // Specific Timings
  static const Duration numberCountUp = Duration(milliseconds: 650);
  static const Duration chartAnimation = Duration(milliseconds: 800);
}
