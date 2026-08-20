import 'package:flutter/material.dart';

import '../app_typography.dart';
import 'mali_card.dart';
import '../../utils/app_lucide_icons.dart';

/// InsightCard — the one accent-gradient surface per screen (AI insight /
/// ملخص الأسبوع). Restraint is deliberate: the balance hero and everything
/// else stay on the canvas; only this earns the gradient (design doc §0.2).
/// Pure presentation — text is passed in already composed.
class InsightCard extends StatelessWidget {
  const InsightCard({
    super.key,
    required this.label,
    required this.message,
    this.ctaText,
    this.onTap,
    this.icon = AppLucideIcons.sparkles,
  });

  /// Small uppercase eyebrow, e.g. "مساعد مالي".
  final String label;
  final String message;
  final String? ctaText;
  final VoidCallback? onTap;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    const onAccent = Colors.white;
    return MaliCard(
      style: MaliSurfaceStyle.accent,
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Icon chip instead of a bare glyph — quieter, more premium.
              Container(
                width: 26,
                height: 26,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: onAccent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: onAccent, size: 14),
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: AppTypography.label(
                  onAccent.withValues(alpha: 0.9),
                ).copyWith(letterSpacing: 0.5),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Padding(
            // Slightly shorter lines read better in RTL.
            padding: const EdgeInsetsDirectional.only(end: 10),
            child: Text(
              message,
              style: AppTypography.callout(onAccent).copyWith(height: 1.65),
            ),
          ),
          if (ctaText != null) ...[
            const SizedBox(height: 15),
            GestureDetector(
              onTap: onTap,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
                decoration: BoxDecoration(
                  color: onAccent.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: onAccent.withValues(alpha: 0.24)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(ctaText!, style: AppTypography.subhead(onAccent)),
                    const SizedBox(width: 6),
                    const Icon(AppLucideIcons.chevronLeft,
                        color: onAccent, size: 18),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
