import 'package:flutter/material.dart';

import '../app_typography.dart';
import '../mali_tokens.dart';
import 'ring_progress.dart';

/// ScoreGauge — a compact ring for a 0..[max] score (e.g. درجة قرش), with the
/// number and an optional caption in the center. Composes [RingProgress];
/// carries no scoring logic. Pass [value] null for the no-data state.
class ScoreGauge extends StatelessWidget {
  const ScoreGauge({
    super.key,
    required this.score,
    this.max = 100,
    this.caption,
    this.size = 96,
    this.color,
  });

  final int? score;
  final int max;
  final String? caption;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final t = MaliTokens.of(context);
    final value = (score == null || max <= 0) ? null : score! / max;
    return RingProgress(
      value: value,
      size: size,
      strokeWidth: 8,
      color: color ?? MaliTokens.accentStart,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            score?.toString() ?? '—',
            style: AppTypography.title1(t.textOnCanvasPrimary),
          ),
          if (caption != null)
            Text(caption!, style: AppTypography.micro(t.textOnCanvasMuted)),
        ],
      ),
    );
  }
}
