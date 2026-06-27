import 'package:flutter/material.dart';

/// AppMotion — Centralized motion durations and curves for Qirsh.
class AppMotion {
  AppMotion._();

  // Durations
  static const Duration fast = Duration(milliseconds: 120);
  static const Duration normal = Duration(milliseconds: 220);
  static const Duration slow = Duration(milliseconds: 360);
  static const Duration emphasized = Duration(milliseconds: 480);
  static const Duration buttonPress = Duration(milliseconds: 90);
  static const Duration cardReveal = Duration(milliseconds: 280);
  static const Duration sheetEnter = Duration(milliseconds: 320);
  static const Duration sheetExit = Duration(milliseconds: 220);

  // Curves
  static const Curve standardCurve = Curves.easeOutCubic;
  static const Curve emphasizedCurve = Curves.easeInOutCubic;
  static const Curve sheetCurve = Curves.easeOutQuart;
  static const Curve buttonCurve = Curves.easeOut;
  static const Curve cardRevealCurve = Curves.easeOutCubic;

  // Specific timings
  static const Duration numberCountUp = Duration(milliseconds: 650);
  static const Duration chartAnimation = Duration(milliseconds: 800);
}
