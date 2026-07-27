import 'package:flutter/material.dart';

import '../app_typography.dart';
import '../mali_tokens.dart';
import 'mali_card.dart';

/// One at-a-glance metric in a [PulseRow].
class PulseMetric {
  const PulseMetric({required this.label, required this.value, this.color});

  final String label;
  final String value;

  /// Value color; defaults to on-canvas primary (e.g. income green / expense
  /// red / neutral for the net).
  final Color? color;
}

/// PulseRow — a quiet strip of at-a-glance metrics (e.g. today's دخل / مصروف /
/// الصافي), separated by hairline dividers. Pure presentation.
class PulseRow extends StatelessWidget {
  const PulseRow({super.key, required this.metrics});

  final List<PulseMetric> metrics;

  @override
  Widget build(BuildContext context) {
    final t = MaliTokens.of(context);
    return MaliCard(
      style: MaliSurfaceStyle.raised,
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
      child: Row(
        children: [
          for (var i = 0; i < metrics.length; i++) ...[
            Expanded(
              child: Column(
                children: [
                  Text(
                    metrics[i].label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.caption(t.textOnCanvasMuted),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    metrics[i].value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.amountSmall(
                      metrics[i].color ?? t.textOnCanvasPrimary,
                    ),
                  ),
                ],
              ),
            ),
            if (i != metrics.length - 1)
              Container(width: 1, height: 34, color: t.strokeSoft),
          ],
        ],
      ),
    );
  }
}
