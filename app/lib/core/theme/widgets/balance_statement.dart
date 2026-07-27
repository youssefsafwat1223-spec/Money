import 'package:flutter/material.dart';

import '../app_typography.dart';
import '../mali_tokens.dart';

/// BalanceStatement — the Home hero: the total balance rendered as a calm
/// statement directly on the canvas (never inside a gradient card — design doc
/// §0.2). Compact two-line layout: the label + eye with the quiet trend pushed
/// to the far end on the first line, and the big amount (+ currency) on the
/// second line with an optional [trailing] (e.g. a Sparkline) at the end. The
/// amount scales down to fit rather than overflow.
class BalanceStatement extends StatelessWidget {
  const BalanceStatement({
    super.key,
    required this.label,
    required this.amount,
    required this.currency,
    this.trendText,
    this.trendColor,
    this.trendIcon,
    this.trailing,
    this.labelTrailing,
  });

  final String label;
  final String amount;
  final String currency;
  final String? trendText;
  final Color? trendColor;
  final IconData? trendIcon;
  final Widget? trailing;

  /// Optional action beside the label (e.g. a privacy hide/show toggle).
  final Widget? labelTrailing;

  @override
  Widget build(BuildContext context) {
    final t = MaliTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Line 1 — label + eye, with the trend pushed to the far end.
        Row(
          children: [
            Text(label,
                style: AppTypography.callout(t.textOnCanvasSecondary)),
            if (labelTrailing != null) ...[
              const SizedBox(width: 8),
              labelTrailing!,
            ],
            if (trendText != null) ...[
              const SizedBox(width: 10),
              Expanded(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (trendIcon != null) ...[
                      Icon(trendIcon,
                          size: 14,
                          color: trendColor ?? t.textOnCanvasSecondary),
                      const SizedBox(width: 4),
                    ],
                    Flexible(
                      child: Text(
                        trendText!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.caption(
                                trendColor ?? t.textOnCanvasSecondary)
                            .copyWith(
                                fontWeight: FontWeight.w600, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 6),
        // Line 2 — the big amount (+ currency), with the trailing at the end.
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: AlignmentDirectional.centerStart,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      amount,
                      style: AppTypography.balanceHero(t.textOnCanvasPrimary)
                          .copyWith(fontSize: 38),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      currency,
                      style: AppTypography.title2(t.textOnCanvasSecondary)
                          .copyWith(fontSize: 16),
                    ),
                  ],
                ),
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 12),
              trailing!,
            ],
          ],
        ),
      ],
    );
  }
}
