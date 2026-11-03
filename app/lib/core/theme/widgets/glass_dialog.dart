import 'package:flutter/material.dart';

import '../app_colors.dart';

/// An [AlertDialog] on the approved opaque dialog surface.
///
/// Same title / content / actions layout and the same [DialogThemeData] text
/// styles as [AlertDialog]. The opaque surface preserves text contrast over
/// busy financial screens in either appearance.
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
    final inheritedButtonStyle = TextButtonTheme.of(context).style;
    Widget actionBar() {
      final bar = OverflowBar(
        alignment: MainAxisAlignment.end,
        overflowAlignment: OverflowBarAlignment.end,
        spacing: 8,
        children: actions!,
      );
      if (theme.brightness != Brightness.dark) return bar;
      return TextButtonTheme(
        data: TextButtonThemeData(
          style: (inheritedButtonStyle ?? const ButtonStyle()).copyWith(
            foregroundColor: WidgetStateProperty.resolveWith((states) {
              final inherited = inheritedButtonStyle?.foregroundColor?.resolve(states);
              if (inherited != null || states.contains(WidgetState.disabled)) {
                return inherited;
              }
              return theme.extension<AppColors>()?.textPrimary ?? theme.colorScheme.onSurface;
            }),
          ),
        ),
        child: bar,
      );
    }
    return Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      elevation: 0,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 280),
        child: Material(
          color: theme.brightness == Brightness.dark
              ? const Color(0xFF1C1F25)
              : theme.extension<AppColors>()?.surface ?? theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(22),
          clipBehavior: Clip.antiAlias,
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
                    child: actionBar(),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
