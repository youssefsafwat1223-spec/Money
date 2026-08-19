import 'package:flutter/material.dart';

import '../app_typography.dart';
import '../mali_tokens.dart';
import '../../utils/app_lucide_icons.dart';
import '../app_colors.dart';

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
    final c = context.colors;
    // سطح صلب — الزجاج محجوز للشيتات وأزرار الهيدر العلوية بس.
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        constraints: const BoxConstraints(minHeight: 44),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: c.divider),
        ),
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
            Icon(AppLucideIcons.chevronDown,
                size: 16, color: t.textOnCanvasMuted),
          ],
        ),
      ),
    );
  }
}
