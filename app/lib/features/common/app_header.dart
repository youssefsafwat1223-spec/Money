import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';

class AppHeader extends StatelessWidget implements PreferredSizeWidget {
  const AppHeader({
    super.key,
    required this.title,
    this.action,
    this.showBack = true,
  });

  final String title;
  final Widget? action;
  final bool showBack;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppBar(
      backgroundColor: c.bg,
      elevation: 0,
      scrolledUnderElevation: 0,
      automaticallyImplyLeading: showBack,
      iconTheme: IconThemeData(color: c.textPrimary),
      title: Text(title, style: AppTypography.title2(c.textPrimary).copyWith(fontWeight: FontWeight.bold)),
      actions: action != null ? [action!, const SizedBox(width: AppSpacing.gutter)] : null,
      centerTitle: false,
    );
  }

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);
}
