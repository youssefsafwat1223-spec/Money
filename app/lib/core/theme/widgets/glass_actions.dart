import 'package:flutter/material.dart';

import '../app_colors.dart';
import 'glass_sheet.dart';

/// One row of [showGlassActions].
class GlassAction<T> {
  const GlassAction({
    required this.value,
    required this.label,
    this.icon,
    this.destructive = false,
  });

  final T value;
  final String label;
  final IconData? icon;
  final bool destructive;
}

/// An action list on the Liquid Glass sheet — the iOS 26 replacement for a
/// Material [PopupMenuButton] menu, which is an opaque surface. Returns the
/// chosen action's value, or null when dismissed.
Future<T?> showGlassActions<T>({
  required BuildContext context,
  required List<GlassAction<T>> actions,
}) {
  return showGlassSheet<T>(
    context: context,
    builder: (sheetContext) {
      final c = sheetContext.colors;
      return SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final action in actions)
              ListTile(
                leading: action.icon == null
                    ? null
                    : Icon(action.icon,
                        color: action.destructive ? c.danger : c.textPrimary),
                title: Text(
                  action.label,
                  style: TextStyle(
                    color: action.destructive ? c.danger : c.textPrimary,
                  ),
                ),
                onTap: () => Navigator.of(sheetContext).pop(action.value),
              ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
}
