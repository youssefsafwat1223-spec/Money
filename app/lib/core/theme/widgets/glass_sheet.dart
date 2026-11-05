import 'package:flutter/material.dart';

import '../app_colors.dart';
import '../app_spacing.dart';
import 'mali_glass.dart';
import 'navy_sheet_theme.dart';

/// [showModalBottomSheet] on the Liquid Glass sheet material.
///
/// For sheets whose content does not bring its own surface (no
/// `AppSheetScaffold`): the route itself is transparent and the content sits
/// on [MaliGlassVariant.sheet] with the same drag handle as `AppSheetScaffold`.
Future<T?> showGlassSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
  bool showDragHandle = true,
  bool useSafeArea = false,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: isScrollControlled,
    useSafeArea: useSafeArea,
    backgroundColor: Colors.transparent,
    elevation: 0,
    builder: (sheetContext) => GlassSheetSurface(
      showDragHandle: showDragHandle,
      child: builder(sheetContext),
    ),
  );
}

class GlassSheetSurface extends StatelessWidget {
  const GlassSheetSurface({
    super.key,
    required this.child,
    this.showDragHandle = true,
  });

  final Widget child;
  final bool showDragHandle;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>() ??
        (Theme.of(context).brightness == Brightness.dark
            ? AppColors.dark
            : AppColors.light);
    return MaliGlass(
      variant: MaliGlassVariant.sheet,
      padding: EdgeInsets.zero,
      nativeMaterial: true,
      child: Material(
        color: Colors.transparent,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (showDragHandle) ...[
              const SizedBox(height: AppSpacing.s3),
              Center(
                child: Container(
                  width: 40,
                  height: 5,
                  decoration: BoxDecoration(
                    color: c.textMuted.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.s3),
            ],
            Flexible(child: DismissKeyboardOnOutsideTap(child: child)),
          ],
        ),
      ),
    );
  }
}
