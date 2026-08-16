import 'package:flutter/material.dart';

import '../app_motion.dart';
import '../mali_tokens.dart';

/// RingProgress — CustomPainter arc used for Safe-to-Spend / budget-safety /
/// (later) financial-health. Deliberately generic: this primitive carries no
/// financial logic, only a value and its render.
///
/// [value] is nullable by design — the incomplete-data fallback contract for
/// whatever wires real data in later (design doc §0.8): pass `null` and the
/// ring renders a muted, static "no data yet" state instead of guessing.
class RingProgress extends StatelessWidget {
  const RingProgress({
    super.key,
    required this.value,
    this.size = 120,
    this.strokeWidth = 10,
    this.color,
    this.trackColor,
    this.animate = true,
    this.child,
  });

  /// 0..1, or null for the indeterminate/no-data state. Values outside
  /// [0, 1] are clamped defensively.
  final double? value;
  final double size;
  final double strokeWidth;
  final Color? color;
  final Color? trackColor;
  final bool animate;

  /// Optional center content — a percentage, or a short verdict slot such as
  /// a plain-language line ("وضعك مستقر").
  final Widget? child;

  bool _reduceMotion(BuildContext context) =>
      MediaQuery.maybeOf(context)?.disableAnimations ?? false;

  @override
  Widget build(BuildContext context) {
    final t = MaliTokens.of(context);
    final isIndeterminate = value == null;
    final target = isIndeterminate ? 0.0 : value!.clamp(0.0, 1.0);
    final resolvedColor = isIndeterminate
        ? t.ringIndeterminate
        : (color ?? MaliTokens.accentStart);
    final resolvedTrack =
        isIndeterminate ? t.ringTrackNeutral : (trackColor ?? t.surfaceRaised);

    Widget ring(double animatedValue) {
      return CustomPaint(
        size: Size.square(size),
        painter: _RingPainter(
          value: isIndeterminate ? null : animatedValue,
          strokeWidth: strokeWidth,
          color: resolvedColor,
          trackColor: resolvedTrack,
        ),
        child: child == null
            ? null
            : SizedBox.square(
                dimension: size,
                child: Center(child: child),
              ),
      );
    }

    if (!animate || _reduceMotion(context)) {
      return ring(target);
    }
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: target),
      duration: AppMotion.chartAnimation,
      curve: AppMotion.standardCurve,
      builder: (context, animatedValue, _) => ring(animatedValue),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.value,
    required this.strokeWidth,
    required this.color,
    required this.trackColor,
  });

  /// null draws a full static track only (indeterminate state).
  final double? value;
  final double strokeWidth;
  final Color color;
  final Color trackColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = (size.shortestSide - strokeWidth) / 2;

    final trackPaint = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(center, radius, trackPaint);

    final v = value;
    if (v == null || v <= 0) return;

    final progressPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    const startAngle = -3.14159265 / 2; // 12 o'clock
    final sweep = 2 * 3.14159265 * v.clamp(0.0, 1.0);
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      startAngle,
      sweep,
      false,
      progressPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _RingPainter oldDelegate) =>
      oldDelegate.value != value ||
      oldDelegate.color != color ||
      oldDelegate.trackColor != trackColor ||
      oldDelegate.strokeWidth != strokeWidth;
}
