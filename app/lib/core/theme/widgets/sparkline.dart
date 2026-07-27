import 'package:flutter/material.dart';

import '../mali_tokens.dart';

/// Sparkline — a minimal trend line for the hero balance / mini-chart
/// moments. Pure presentation, no data logic. Defensively handles empty,
/// single-point, and flat (all-equal) data without dividing by zero.
class Sparkline extends StatelessWidget {
  const Sparkline({
    super.key,
    required this.values,
    this.color = MaliTokens.accentStart,
    this.strokeWidth = 2.2,
    this.height = 32,
  });

  final List<double> values;
  final Color color;
  final double strokeWidth;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: CustomPaint(
        size: Size.infinite,
        painter: _SparklinePainter(
          values: values,
          color: color,
          strokeWidth: strokeWidth,
        ),
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter({
    required this.values,
    required this.color,
    required this.strokeWidth,
  });

  final List<double> values;
  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2 || size.width <= 0 || size.height <= 0) return;

    final minV = values.reduce((a, b) => a < b ? a : b);
    final maxV = values.reduce((a, b) => a > b ? a : b);
    // Flat data (all-equal) would divide by zero — draw a level mid-line.
    final range = (maxV - minV).abs() < 1e-9 ? 1.0 : (maxV - minV);

    final dx = size.width / (values.length - 1);
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final normalized = (values[i] - minV) / range;
      final x = dx * i;
      final y = size.height - (normalized * size.height);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter oldDelegate) =>
      oldDelegate.values != values ||
      oldDelegate.color != color ||
      oldDelegate.strokeWidth != strokeWidth;
}
