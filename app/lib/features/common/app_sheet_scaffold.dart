import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_shadows.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';

class AppSheetScaffold extends StatelessWidget {
  const AppSheetScaffold({
    super.key,
    this.title,
    this.subtitle,
    required this.body,
    this.bottomAction,
    this.leading,
    this.trailing,
    this.padding,
    this.scrollable = false,
    this.showDragHandle = true,
    this.showCloseButton = true,
  });

  final String? title;
  final String? subtitle;
  final Widget body;
  final Widget? bottomAction;
  final Widget? leading;
  final Widget? trailing;
  final EdgeInsetsGeometry? padding;
  final bool scrollable;
  final bool showDragHandle;
  final bool showCloseButton;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final insets = MediaQuery.paddingOf(context);
    final viewInsets = MediaQuery.viewInsetsOf(context);

    Widget content = body;
    if (padding != null) {
      content = Padding(padding: padding!, child: content);
    }

    if (scrollable) {
      content = SingleChildScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        child: content,
      );
    }

    return ClipRRect(
      borderRadius:
          const BorderRadius.vertical(top: Radius.circular(AppRadius.sheet)),
      child: Material(
        color: c.surfaceElevated,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: c.surfaceElevated,
            border: Border(top: BorderSide(color: c.border)),
            boxShadow: AppShadows.sheet,
          ),
          child: Padding(
            padding: EdgeInsetsDirectional.only(
              bottom: viewInsets.bottom > 0
                  ? viewInsets.bottom + AppSpacing.s4
                  : insets.bottom + AppSpacing.s6,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (showDragHandle) ...[
                  const SizedBox(height: AppSpacing.s3),
                  Center(
                    child: Container(
                      width: 44,
                      height: 5,
                      decoration: BoxDecoration(
                        color: c.textMuted.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(99),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: AppSpacing.s4),
                if (title != null || leading != null || trailing != null)
                  Padding(
                    padding: const EdgeInsetsDirectional.symmetric(
                      horizontal: AppSpacing.gutter,
                    ),
                    child: Row(
                      children: [
                        if (leading != null) ...[
                          leading!,
                          const SizedBox(width: AppSpacing.s3),
                        ],
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (title != null)
                                Text(
                                  title!,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTypography.title2(c.textPrimary),
                                ),
                              if (subtitle != null) ...[
                                const SizedBox(height: 2),
                                Text(
                                  subtitle!,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTypography.caption(c.textSecondary),
                                ),
                              ],
                            ],
                          ),
                        ),
                        if (trailing != null) ...[
                          const SizedBox(width: AppSpacing.s3),
                          trailing!,
                        ] else if (showCloseButton) ...[
                          const SizedBox(width: AppSpacing.s3),
                          IconButton(
                            onPressed: () => Navigator.of(context).pop(),
                            icon: const Icon(Icons.close_rounded),
                            color: c.textSecondary,
                          ),
                        ],
                      ],
                    ),
                  ),
                if (title != null || leading != null || trailing != null)
                  const SizedBox(height: AppSpacing.s4),
                Flexible(child: content),
                if (bottomAction != null) ...[
                  const SizedBox(height: AppSpacing.s4),
                  Padding(
                    padding: const EdgeInsetsDirectional.symmetric(
                      horizontal: AppSpacing.gutter,
                    ),
                    child: bottomAction!,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
