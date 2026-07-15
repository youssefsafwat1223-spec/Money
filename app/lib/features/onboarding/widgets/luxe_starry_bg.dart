import 'dart:math';
import 'package:flutter/material.dart';

class LuxeStarryBackground extends StatefulWidget {
  const LuxeStarryBackground({super.key, this.offset = 0.0});
  final double offset;

  @override
  State<LuxeStarryBackground> createState() => _LuxeStarryBackgroundState();
}

class _LuxeStarryBackgroundState extends State<LuxeStarryBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  final List<_Star> _stars = [];
  final Random _random = Random(42); // Fixed seed for consistent star placement

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
    )..repeat(reverse: true);

    // Generate stars
    for (int i = 0; i < 50; i++) {
      _stars.add(_Star(
        x: _random.nextDouble(),
        y: _random.nextDouble(),
        size: _random.nextDouble() * 2 + 0.5,
        twinklePhase: _random.nextDouble() * pi * 2,
        depth: _random.nextDouble() * 0.8 + 0.2, // Speed factor for parallax
      ));
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      color: isDark
          ? Colors.black
          : const Color(0xFFF3F4F6), // Theme-aware background
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return CustomPaint(
            painter: _StarryPainter(
              stars: _stars,
              time: _controller.value,
              offset: widget.offset,
              isDark: isDark,
            ),
            size: Size.infinite,
          );
        },
      ),
    );
  }
}

class _Star {
  final double x;
  final double y;
  final double size;
  final double twinklePhase;
  final double depth;

  _Star({
    required this.x,
    required this.y,
    required this.size,
    required this.twinklePhase,
    required this.depth,
  });
}

class _StarryPainter extends CustomPainter {
  final List<_Star> stars;
  final double time;
  final double offset;
  final bool isDark;

  _StarryPainter({
    required this.stars,
    required this.time,
    required this.offset,
    required this.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();

    for (final star in stars) {
      // Twinkle effect (opacity varies slowly)
      final opacity = (sin(time * pi * 2 + star.twinklePhase) + 1) / 2;
      if (isDark) {
        paint.color =
            const Color(0xFFDAA520).withValues(alpha: opacity * 0.6 + 0.1);
      } else {
        paint.color = const Color(0xFF1E3A8A).withValues(
            alpha: opacity * 0.35 + 0.05); // Soft blue particles in light mode
      }

      // Parallax shift: shift X coordinates based on scroll offset and star depth
      // Using modulo to wrap stars around screen edges
      double shiftedX = (star.x - (offset * 0.15 * star.depth)) % 1.0;
      if (shiftedX < 0) shiftedX += 1.0;

      canvas.drawCircle(
        Offset(shiftedX * size.width, star.y * size.height),
        star.size,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _StarryPainter oldDelegate) {
    return oldDelegate.time != time || oldDelegate.offset != offset;
  }
}
