import 'package:flutter/material.dart';

import '../app_colors.dart';
import '../app_typography.dart';
import '../mali_tokens.dart';

/// LedgerRow — one transaction line for the day-grouped timeline: a tinted
/// category icon, merchant + "category · time" subtitle, and the signed
/// amount, with optional pending / AI-parsed badges. Pure presentation.
class LedgerRow extends StatelessWidget {
  const LedgerRow({
    super.key,
    required this.icon,
    required this.iconTint,
    required this.title,
    required this.subtitle,
    required this.amount,
    this.amountColor,
    this.isPending = false,
    this.isAi = false,
    this.onTap,
  });

  final IconData icon;
  final Color iconTint;
  final String title;
  final String subtitle;
  final String amount;
  final Color? amountColor;
  final bool isPending;
  final bool isAi;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = MaliTokens.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: iconTint.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(icon, color: iconTint, size: 20),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTypography.bodyStrong(
                                t.textOnCanvasPrimary),
                          ),
                        ),
                        // Compact pills — a dense timeline row can't afford a
                        // long "قيد المراجعة" here (it would crowd out the
                        // merchant name); the full label lives on the details
                        // screen.
                        if (isPending)
                          _Badge(text: 'مراجعة', color: c.warning),
                        if (isAi) _Badge(text: 'ذكاء', color: c.cta),
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
              Text(
                amount,
                style: AppTypography.amountSmall(
                    amountColor ?? t.textOnCanvasPrimary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 7),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(text, style: AppTypography.micro(color)),
      ),
    );
  }
}
