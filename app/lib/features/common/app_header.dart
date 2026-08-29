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
    this.titleMaxLines = 1,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final Widget? action;
  final bool showBack;
  final bool compact;

  /// UX-014 — how many lines the title may occupy before it ellipsises.
  ///
  /// One line is right for a fixed screen name («الحسابات والمحافظ»). It is
  /// wrong for a title that is USER DATA: an account named «الراجحي — الحساب
  /// الجاري» rendered as «الراجحي — الحساب ال…» while «مدى — البطاقة الرئيسية»
  /// happened to fit, so whether you could read your own account's name
  /// depended on how long you had made it.
  ///
  /// Opt-in rather than a global default: raising it everywhere would give
  /// every screen a two-line header for no benefit, and the bar's height has to
  /// grow with it.
  final int titleMaxLines;

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
            maxLines: titleMaxLines,
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
  Size get preferredSize {
    final base = subtitle == null ? 56.0 : 68.0;
    // The title style is 24px with tight leading; each extra permitted line
    // needs its own room or the AppBar clips what it just allowed to wrap.
    return Size.fromHeight(base + (titleMaxLines - 1) * 28.0);
  }
}
