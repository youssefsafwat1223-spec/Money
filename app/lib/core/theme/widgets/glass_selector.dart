import 'package:flutter/material.dart';

import '../app_typography.dart';
import '../mali_tokens.dart';
import 'glass_surface.dart';

/// GlassSelector — the shared frosted selector chip (account / date-range /
/// currency …): a muted icon, a label, and a chevron, on a real backdrop-blur
/// glass surface. Tapping runs [onTap] (usually opening a picker sheet).
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
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: GlassSurface(
        borderRadius: BorderRadius.circular(16),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(
          children: [
            Icon(icon, size: 16, color: t.textOnCanvasSecondary),
            const SizedBox(width: 8),
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
                size: 18, color: t.textOnCanvasMuted),
          ],
        ),
      ),
    );
  }
}
