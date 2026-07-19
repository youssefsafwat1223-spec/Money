import 'package:flutter/material.dart';

import '../app_theme.dart';

/// Applies Qirsh's navy sheet palette to modal content in every app theme.
Widget navySheetTheme(Widget child) {
  return Theme(
    data: AppTheme.sheet,
    child: child,
  );
}
