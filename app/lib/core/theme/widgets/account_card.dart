import 'package:flutter/material.dart';

import '../app_colors.dart';
import '../app_spacing.dart';
import '../app_typography.dart';
import '../mali_tokens.dart';
import 'mali_card.dart';

/// AccountCard — one account/wallet row: a tinted type mark, name (+ optional
/// "افتراضي" badge), "type · currency" subtitle, and the balance in its own
/// currency. Pure presentation.
class AccountCard extends StatelessWidget {
  const AccountCard({
    super.key,
    required this.icon,
    required this.tint,
    required this.name,
    required this.subtitle,
    required this.balance,
    required this.balanceCurrency,
    this.isDefault = false,
    this.onTap,
  });

  final IconData icon;
  final Color tint;
  final String name;
  final String subtitle;
  final String balance;
  final String balanceCurrency;
  final bool isDefault;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = MaliTokens.of(context);
    return MaliCard(
      style: MaliSurfaceStyle.floating,
      padding: EdgeInsets.zero,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.xxxl),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            child: Row(
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: tint.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(icon, color: tint, size: 22),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppTypography.bodyStrong(
                                  t.textOnCanvasPrimary),
                            ),
                          ),
                          if (isDefault) _DefaultBadge(color: c.cta),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.caption(t.textOnCanvasMuted),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      balance,
                      style:
                          AppTypography.amountSmall(t.textOnCanvasPrimary),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      balanceCurrency,
                      style: AppTypography.micro(t.textOnCanvasMuted),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DefaultBadge extends StatelessWidget {
  const _DefaultBadge({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text('افتراضي', style: AppTypography.micro(color)),
      ),
    );
  }
}
