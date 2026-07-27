import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_motion.dart';
import '../mali_tokens.dart';

/// One slice of a [DonutChart].
class DonutSegment {
  const DonutSegment({required this.value, required this.color, this.label});

  final double value;
  final Color color;
  final String? label;
}

/// DonutChart — category spend breakdown as a ring of proportional arcs, with
/// an optional [center] slot (e.g. total). Pure presentation. When all values
/// are zero it renders the neutral track only (no-data state). Animates the
/// sweep in unless motion is reduced.
class DonutChart extends StatelessWidget {
  const DonutChart({
    super.key,
    required this.segments,
    this.size = 118,
    this.strokeWidth = 20,
    this.center,
    this.gapDegrees = 3,
    this.animate = true,
  });

  final List<DonutSegment> segments;
  final double size;
  final double strokeWidth;
  final Widget? center;
  final double gapDegrees;
  final bool animate;

  @override
  Widget build(BuildContext context) {
    final t = MaliTokens.of(context);
    final total = segments.fold<double>(0, (s, seg) => s + seg.value);

    Widget paint(double progress) => CustomPaint(
          size: Size.square(size),
          painter: _DonutPainter(
            segments: segments,
            total: total,
            strokeWidth: strokeWidth,
            gapDegrees: gapDegrees,
            trackColor: t.ringTrackNeutral,
            progress: progress,
          ),
          child: center == null
              ? null
              : SizedBox.square(dimension: size, child: Center(child: center)),
        );

    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (!animate || reduce || total <= 0) return paint(1);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: AppMotion.chartAnimation,
      curve: AppMotion.standardCurve,
      builder: (_, v, __) => paint(v),
    );
  }
}

class _DonutPainter extends CustomPainter {
  _DonutPainter({
    required this.segments,
    required this.total,
    required this.strokeWidth,
    required this.gapDegrees,
    required this.trackColor,
    required this.progress,
  });

  final List<DonutSegment> segments;
  final double total;
  final double strokeWidth;
  final double gapDegrees;
  final Color trackColor;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = (size.shortestSide - strokeWidth) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);
    const startBase = -math.pi / 2;
    final gap = gapDegrees * math.pi / 180;

    if (total <= 0) {
      final track = Paint()
        ..color = trackColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth;
      canvas.drawCircle(center, radius, track);
      return;
    }

    var start = startBase;
    for (final seg in segments) {
      if (seg.value <= 0) continue;
      final full = (seg.value / total) * (2 * math.pi);
      final sweep = (full - gap).clamp(0.0, 2 * math.pi) * progress;
      final paint = Paint()
        ..color = seg.color
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(rect, start + gap / 2, sweep, false, paint);
      start += full;
    }
  }

  @override
  bool shouldRepaint(covariant _DonutPainter old) =>
      old.progress != progress ||
      old.total != total ||
      old.segments != segments;
}
