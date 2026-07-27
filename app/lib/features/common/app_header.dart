import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';

class AppHeader extends StatelessWidget implements PreferredSizeWidget {
  const AppHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.action,
    this.showBack = true,
    this.compact = false,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final Widget? action;
  final bool showBack;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppBar(
      backgroundColor: c.bg,
      elevation: 0,
      scrolledUnderElevation: 0,
      automaticallyImplyLeading: leading == null && showBack,
      leading: leading,
      iconTheme: IconThemeData(color: c.textPrimary),
      titleSpacing: AppSpacing.s4,
      toolbarHeight: preferredSize.height,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            // Mockup `.tophead .h1`: 24px w600, tight tracking.
            style: compact
                ? AppTypography.headline(c.textPrimary)
                    .copyWith(fontWeight: FontWeight.w600)
                : AppTypography.calmTitle(c.textPrimary)
                    .copyWith(fontSize: 24, letterSpacing: -0.5),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 2),
            Text(
              subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              // Mockup `.hsub`: 13px secondary.
              style: AppTypography.caption(c.textSecondary)
                  .copyWith(fontSize: 13, fontWeight: FontWeight.w400),
            ),
          ],
        ],
      ),
      actions: [
        if (trailing != null) trailing!,
        if (action != null) action!,
        if (trailing != null || action != null)
          const SizedBox(width: AppSpacing.gutter),
      ],
      centerTitle: false,
    );
  }

  @override
  Size get preferredSize => Size.fromHeight(subtitle == null ? 56 : 68);
}
