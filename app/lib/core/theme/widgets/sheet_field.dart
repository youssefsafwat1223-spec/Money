import 'package:flutter/material.dart';

import '../app_typography.dart';
import '../mali_tokens.dart';
import '../../utils/app_lucide_icons.dart';

/// SheetField — a labeled, tappable field row for the manual-add sheet
/// (الحساب / التصنيف / التاريخ …): a muted icon, the label over its value (or a
/// placeholder), and an optional chevron. Pure presentation + a callback.
class SheetField extends StatelessWidget {
  const SheetField({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.isPlaceholder = false,
    this.onTap,
    this.showChevron = true,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool isPlaceholder;
  final VoidCallback? onTap;
  final bool showChevron;

  @override
  Widget build(BuildContext context) {
    final t = MaliTokens.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          // Mockup `.field`: raised, radius 16, padding 15/16, label 11 / value 14.5.
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
          decoration: BoxDecoration(
            color: t.surfaceRaised,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Icon(icon, size: 20, color: t.textOnCanvasMuted),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: AppTypography.caption(t.textOnCanvasMuted)
                          .copyWith(fontSize: 11),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: (isPlaceholder
                              ? AppTypography.subhead(t.textOnCanvasMuted)
                                  .copyWith(fontWeight: FontWeight.w400)
                              : AppTypography.bodyStrong(t.textOnCanvasPrimary))
                          .copyWith(fontSize: 14.5),
                    ),
                  ],
                ),
              ),
              if (showChevron && onTap != null)
                Icon(AppLucideIcons.chevronLeft,
                    size: 20, color: t.textOnCanvasMuted),
            ],
          ),
        ),
      ),
    );
  }
}
