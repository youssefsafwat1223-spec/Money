import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// The small trend drawing inside Home's blue hero.
///
/// Two shapes, one job — "how does this period sit against what it should
/// be":
///   * [HeroTrendChart.line] — a cumulative line against a dashed reference
///     (the month against its budget pace, today against a typical day);
///   * [HeroTrendChart.bars] — seven daily bars against a dashed average.
///
/// Guide colors adapt to the surface behind the chart. No axis,
/// legend, tooltip or gesture — context for the hero number, not analytics
/// (`test/features/dashboard/no_charts_on_home_test.dart` keeps the chart
/// library out of Home).
class HeroTrendChart extends StatelessWidget {
  const HeroTrendChart.line({
    super.key,
    required this.values,
    required this.slots,
    required this.reference,
    required this.color,
    this.height = 96,
    this.guideColor = Colors.white,
  })  : bars = false,
        _average = null;

  const HeroTrendChart.bars({
    super.key,
    required this.values,
    required this.color,
    double? average,
    this.height = 96,
    this.guideColor = Colors.white,
  })  : bars = true,
        slots = 7,
        reference = null,
        _average = average;

  /// Line: cumulative points from slot 0. Bars: one value per bar, oldest
  /// first, the last one is today.
  final List<double> values;

  /// How many slots the x axis spans; the line may stop before the end.
  final int slots;

  /// Line: the dashed reference, one point per slot from 0..[slots].
  final List<double>? reference;
  final Color color;
  final Color guideColor;
  final double height;
  final bool bars;
  final double? _average;

  @override
  Widget build(BuildContext context) {
    final animate = !(MediaQuery.maybeDisableAnimationsOf(context) ?? false);
    return SizedBox(
      height: height,
      width: double.infinity,
      child: TweenAnimationBuilder<double>(
        // Re-keyed by the caller per period, so switching tabs redraws.
        tween: Tween(begin: animate ? 0 : 1, end: 1),
        duration: const Duration(milliseconds: 700),
        curve: Curves.easeOutCubic,
        builder: (context, t, _) => CustomPaint(
          painter: bars
              ? _BarsPainter(values, _average, color, guideColor, t)
              : _LinePainter(values, slots, reference ?? const [], color, guideColor, t),
        ),
      ),
    );
  }
}

void _dashed(Canvas canvas, Path path, Paint paint) {
  for (final metric in path.computeMetrics()) {
    var d = 0.0;
    while (d < metric.length) {
      canvas.drawPath(metric.extractPath(d, math.min(d + 4, metric.length)), paint);
      d += 9;
    }
  }
}

class _LinePainter extends CustomPainter {
  _LinePainter(this.values, this.slots, this.reference, this.color, this.guideColor, this.t);

  final List<double> values;
  final int slots;
  final List<double> reference;
  final Color color;
  final Color guideColor;
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height - 6;
    var maxV = 1.0;
    for (final v in [...values, ...reference]) {
      if (v > maxV) maxV = v;
    }
    maxV *= 1.08;
    double x(int i) => slots == 0 ? 0 : i / slots * w;
    double y(double v) => h - v.clamp(0, maxV) / maxV * (h - 6);

    canvas.drawLine(Offset(0, h), Offset(w, h), Paint()..color = guideColor.withValues(alpha: 0.14));

    if (reference.length > 1) {
      final ref = Path()..moveTo(x(0), y(reference.first));
      for (var i = 1; i < reference.length; i++) {
        ref.lineTo(x(i), y(reference[i]));
      }
      _dashed(
        canvas,
        ref,
        Paint()
          ..color = guideColor.withValues(alpha: 0.42)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6,
      );
    }
    if (values.length < 2) return;

    final line = Path()..moveTo(x(0), y(values.first));
    for (var i = 1; i < values.length; i++) {
      line.lineTo(x(i), y(values[i]));
    }
    final metric = line.computeMetrics().first;
    final drawn = metric.extractPath(0, metric.length * t);
    final tip = metric.getTangentForOffset(metric.length * t)?.position ??
        Offset(x(values.length - 1), y(values.last));

    final area = Path.from(drawn)
      ..lineTo(tip.dx, h)
      ..lineTo(0, h)
      ..close();
    canvas.drawPath(
      area,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset.zero,
          Offset(0, h),
          [color.withValues(alpha: 0.34), color.withValues(alpha: 0)],
        ),
    );
    canvas.drawPath(
      drawn,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.6
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    if (t >= 1) {
      canvas.drawCircle(tip, 9, Paint()..color = color.withValues(alpha: 0.25));
      canvas.drawCircle(tip, 5, Paint()..color = Colors.white);
      canvas.drawCircle(
        tip,
        5,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3,
      );
    }
  }

  @override
  bool shouldRepaint(_LinePainter old) =>
      old.t != t ||
      old.color != color ||
      old.guideColor != guideColor ||
      old.slots != slots ||
      old.values != values ||
      old.reference != reference;
}

class _BarsPainter extends CustomPainter {
  _BarsPainter(this.values, this.average, this.color, this.guideColor, this.t);

  final List<double> values;
  final double? average;
  final Color color;
  final Color guideColor;
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final w = size.width, h = size.height - 6;
    var maxV = 1.0;
    for (final v in [...values, average ?? 0]) {
      if (v > maxV) maxV = v;
    }
    maxV *= 1.1;
    const gap = 10.0;
    final bw = (w - gap * (values.length - 1)) / values.length;
    for (var i = 0; i < values.length; i++) {
      final v = math.max(0.0, values[i]) * t;
      final bh = math.max(3.0, v / maxV * (h - 4));
      final r = RRect.fromRectAndCorners(
        Rect.fromLTWH(i * (bw + gap), h - bh, bw, bh),
        topLeft: const Radius.circular(6),
        topRight: const Radius.circular(6),
        bottomLeft: const Radius.circular(2),
        bottomRight: const Radius.circular(2),
      );
      final today = i == values.length - 1;
      canvas.drawRRect(
          r, Paint()..color = today ? color : guideColor.withValues(alpha: 0.22));
    }
    final avg = average;
    if (avg != null && avg > 0) {
      final ay = h - avg / maxV * (h - 4);
      _dashed(
        canvas,
        Path()
          ..moveTo(0, ay)
          ..lineTo(w, ay),
        Paint()
          ..color = guideColor.withValues(alpha: 0.42)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4,
      );
    }
    canvas.drawLine(Offset(0, h), Offset(w, h), Paint()..color = guideColor.withValues(alpha: 0.14));
  }

  @override
  bool shouldRepaint(_BarsPainter old) =>
      old.t != t || old.color != color ||
      old.guideColor != guideColor || old.values != values || old.average != average;
}
