import 'package:flutter/material.dart';

import '../app_typography.dart';
import '../mali_tokens.dart';
import 'mali_glass.dart';

/// GlassSelector — the shared frosted selector chip (account / date-range /
/// currency …): a muted icon, a label, and a chevron, on [MaliGlass].
/// Tapping runs [onTap] (usually opening a picker sheet); the material adds
/// the Tier 2 press response and button semantics.
///
/// This is the single implementation used by Home, Transactions, and every
/// other screen — edit it here to restyle every selector at once.
class GlassSelector extends StatelessWidget {
  const GlassSelector({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = MaliTokens.of(context);
    return MaliGlass(
      variant: MaliGlassVariant.pill,
      radius: 16,
      onTap: onTap,
      // Compact premium control (not a card): tighter padding, smaller
      // glyphs. MaliGlass still guarantees the ≥44px touch target.
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      child: Row(
        children: [
          Icon(icon, size: 15, color: t.textOnCanvasSecondary),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              // 12.5px per the mockup `.sel` (subhead is 14).
              style: AppTypography.subhead(t.textOnCanvasPrimary)
                  .copyWith(fontSize: 12.5),
            ),
          ),
          Icon(Icons.keyboard_arrow_down_rounded,
              size: 16, color: t.textOnCanvasMuted),
        ],
      ),
    );
  }
}
