import 'package:flutter/material.dart';

import '../app_spacing.dart';
import 'mali_glass.dart';

/// An [AlertDialog] on the Liquid Glass material.
///
/// Same title / content / actions layout and the same [DialogThemeData] text
/// styles as [AlertDialog]; the surface is [MaliGlass] instead of an opaque
/// Material, so the dialog reads as glass over the dimmed page.
class GlassAlertDialog extends StatelessWidget {
  const GlassAlertDialog({
    super.key,
    this.title,
    this.content,
    this.actions,
    this.actionsPadding,
  });

  final Widget? title;
  final Widget? content;
  final List<Widget>? actions;
  final EdgeInsetsGeometry? actionsPadding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dialogTheme = DialogTheme.of(context);
    return Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      elevation: 0,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 280),
        child: MaliGlass(
          variant: MaliGlassVariant.card,
          radius: AppRadius.sheet,
          padding: EdgeInsets.zero,
          nativeMaterial: true,
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (title != null)
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                        24, 24, 24, content == null ? 20 : 0),
                    child: DefaultTextStyle(
                      style: dialogTheme.titleTextStyle ??
                          theme.textTheme.headlineSmall!,
                      child: Semantics(
                        namesRoute: true,
                        container: true,
                        child: title!,
                      ),
                    ),
                  ),
                if (content != null)
                  Flexible(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                          24, title == null ? 20 : 16, 24, 0),
                      child: DefaultTextStyle(
                        style: dialogTheme.contentTextStyle ??
                            theme.textTheme.bodyMedium!,
                        child: content!,
                      ),
                    ),
                  ),
                if (actions != null && actions!.isNotEmpty)
                  Padding(
                    padding: actionsPadding ??
                        const EdgeInsets.fromLTRB(16, 16, 16, 16),
                    child: OverflowBar(
                      alignment: MainAxisAlignment.end,
                      overflowAlignment: OverflowBarAlignment.end,
                      spacing: 8,
                      children: actions!,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
