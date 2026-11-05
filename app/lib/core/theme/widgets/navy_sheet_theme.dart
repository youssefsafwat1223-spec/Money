import 'package:flutter/material.dart';

import '../app_theme.dart';

/// Applies the neutral Calm Capital sheet palette to modal content — charcoal
/// in dark, white in light (mali_pages.html), matching every other sheet.
///
/// (Named `navySheetTheme` for its call-sites' history; it now follows the
/// ambient brightness rather than forcing navy.)
Widget navySheetTheme(Widget child) {
  return Builder(
    builder: (context) {
      final isDark = Theme.of(context).brightness == Brightness.dark;
      return Theme(
        data: isDark ? AppTheme.dark : AppTheme.light,
        child: DismissKeyboardOnOutsideTap(child: child),
      );
    },
  );
}

/// Native mobile text fields keep focus on outside touches by default.
class DismissKeyboardOnOutsideTap extends StatelessWidget {
  const DismissKeyboardOnOutsideTap({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Actions(
        actions: <Type, Action<Intent>>{
          EditableTextTapUpOutsideIntent:
              CallbackAction<EditableTextTapUpOutsideIntent>(
            onInvoke: (intent) => intent.focusNode.unfocus(),
          ),
        },
        child: child,
      );
}
