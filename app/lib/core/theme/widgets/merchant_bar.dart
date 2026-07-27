import 'package:flutter/material.dart';

import '../app_typography.dart';
import '../mali_tokens.dart';

/// MerchantBar — one ranked merchant/place spend row: a brand mark, the name
/// over a proportional progress bar, and the amount + operation count. Pure
/// presentation; [fraction] is 0..1 relative to the top merchant.
class MerchantBar extends StatelessWidget {
  const MerchantBar({
    super.key,
    required this.name,
    required this.amount,
    required this.fraction,
    this.meta,
    this.markLabel,
    this.markColor,
  });

  final String name;
  final String amount;
  final double fraction;
  final String? meta;
  final String? markLabel;
  final Color? markColor;

  @override
  Widget build(BuildContext context) {
    final t = MaliTokens.of(context);
    final mark = markColor ?? MaliTokens.accentStart;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: mark,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              (markLabel ?? (name.isNotEmpty ? name.characters.first : '?')),
              style: AppTypography.subhead(Colors.white),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.subhead(t.textOnCanvasPrimary),
                ),
                const SizedBox(height: 7),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: fraction.clamp(0.0, 1.0),
                    minHeight: 6,
                    backgroundColor: t.ringTrackNeutral,
                    valueColor:
                        const AlwaysStoppedAnimation(MaliTokens.accentStart),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                amount,
                style: AppTypography.subhead(t.textOnCanvasPrimary),
              ),
              if (meta != null) ...[
                const SizedBox(height: 3),
                Text(meta!, style: AppTypography.micro(t.textOnCanvasMuted)),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
