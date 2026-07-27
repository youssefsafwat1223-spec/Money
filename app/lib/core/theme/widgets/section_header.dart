import 'package:flutter/material.dart';

import '../app_typography.dart';
import '../mali_tokens.dart';

/// SectionHeader — consistent title (+ optional trailing action) for every
/// section archetype. Defaults to on-canvas colors; override [titleColor] /
/// [trailingColor] when used on a light surface elsewhere in the app.
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.trailing,
    this.onTrailingTap,
    this.titleColor,
    this.trailingColor,
  });

  final String title;
  final String? trailing;
  final VoidCallback? onTrailingTap;

  /// Defaults to the on-canvas primary/secondary for the ambient mode; override
  /// when used on a differently-colored surface.
  final Color? titleColor;
  final Color? trailingColor;

  @override
  Widget build(BuildContext context) {
    final t = MaliTokens.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            // Compact UI system: section titles use the 19px role token.
            style: AppTypography.sectionTitle(
                titleColor ?? t.textOnCanvasPrimary),
          ),
        ),
        if (trailing != null)
          GestureDetector(
            onTap: onTrailingTap,
            child: Text(
              trailing!,
              style: AppTypography.subhead(
                  trailingColor ?? t.textOnCanvasSecondary),
            ),
          ),
      ],
    );
  }
}
