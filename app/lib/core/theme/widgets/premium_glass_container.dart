import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';

/// A premium glassmorphism container that adds a realistic frosted
/// noise grain overlay on top of a standard blurred backdrop.
class PremiumGlassContainer extends StatefulWidget {
  const PremiumGlassContainer({
    super.key,
    required this.child,
    this.borderRadius,
    this.blurSigma = 20,
    this.backgroundColor = Colors.black45,
    this.borderColor = Colors.white10,
    this.noiseOpacity = 0.04,
    this.padding,
  });

  final Widget child;
  final BorderRadius? borderRadius;
  final double blurSigma;
  final Color backgroundColor;
  final Color borderColor;
  final double noiseOpacity;
  final EdgeInsetsGeometry? padding;

  @override
  State<PremiumGlassContainer> createState() => _PremiumGlassContainerState();
}

class _PremiumGlassContainerState extends State<PremiumGlassContainer> {
  @override
  Widget build(BuildContext context) {
    final br = widget.borderRadius ?? BorderRadius.circular(24);

    return ClipRRect(
      borderRadius: br,
      child: BackdropFilter(
        filter: ImageFilter.blur(
            sigmaX: widget.blurSigma, sigmaY: widget.blurSigma),
        child: Container(
          decoration: BoxDecoration(
            color: widget.backgroundColor,
            borderRadius: br,
            border: Border.all(color: widget.borderColor),
          ),
          child: Stack(
            fit: StackFit.loose,
            children: [
              Positioned.fill(
                child: Opacity(
                  opacity: widget.noiseOpacity,
                  child: CustomPaint(
                    painter: _StaticNoisePainter(),
                  ),
                ),
              ),
              Padding(
                padding: widget.padding ?? EdgeInsets.zero,
                child: widget.child,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StaticNoisePainter extends CustomPainter {
  // Use a fixed random seed so the noise pattern doesn't dance every frame
  final Random _random = Random(42);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = 1.0
      ..style = PaintingStyle.fill;

    // Draw a sparse dot pattern to simulate noise
    const step = 2.0;
    for (double y = 0; y < size.height; y += step) {
      for (double x = 0; x < size.width; x += step) {
        if (_random.nextDouble() > 0.5) {
          canvas.drawRect(Rect.fromLTWH(x, y, 1, 1), paint);
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
