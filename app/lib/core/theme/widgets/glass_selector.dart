import 'package:flutter/material.dart';

import '../app_colors.dart';
import '../app_spacing.dart';
import '../app_typography.dart';
import '../../utils/app_lucide_icons.dart';

/// GlassSelector — the shared selector chip (account / date-range /
/// currency …): an icon, a label, and a chevron on a translucent white pill.
/// Tapping runs [onTap] (usually opening a picker sheet).
///
/// Two tones: white-on-blue for Home's melting hero ([onBlue]), and the
/// prototype's `.fchip` (surface, hairline, secondary ink) on the canvas
/// headers every other screen uses. This is the single implementation used
/// by Home, Transactions, and every other screen — edit it here to restyle
/// every selector at once.
class GlassSelector extends StatelessWidget {
  const GlassSelector({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.onBlue = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  /// True when mounted on Home's blue hero.
  final bool onBlue;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final fg = onBlue ? Colors.white : c.textSecondary;
    return Semantics(
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 34),
          padding: const EdgeInsetsDirectional.fromSTEB(10, 6, 12, 6),
          decoration: BoxDecoration(
            color: onBlue ? Colors.white.withValues(alpha: 0.12) : c.surface,
            borderRadius: BorderRadius.circular(AppRadius.pill),
            border: Border.all(
                color: onBlue
                    ? Colors.white.withValues(alpha: 0.16)
                    : c.border),
          ),
          child: Row(
            children: [
              Icon(icon, size: 15, color: fg.withValues(alpha: 0.9)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: onBlue
                      ? AppTypography.caption(fg)
                      : AppTypography.custom(
                          size: 13,
                          weight: FontWeight.w500,
                          height: 1.3,
                          color: fg),
                ),
              ),
              const SizedBox(width: 4),
              Icon(AppLucideIcons.chevronDown,
                  size: 14, color: fg.withValues(alpha: 0.8)),
            ],
          ),
        ),
      ),
    );
  }
}
