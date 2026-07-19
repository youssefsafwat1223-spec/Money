import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../app_colors.dart';

/// A premium animated liquid mesh gradient background.
/// It uses large blurred circles moving in sine waves to create a performant
/// organic liquid feel without needing external shader packages.
class MeshGradientBackground extends StatefulWidget {
  const MeshGradientBackground({
    super.key,
    this.primaryColor,
    this.secondaryColor,
    this.tertiaryColor,
    this.backgroundColor,
  });

  final Color? primaryColor;
  final Color? secondaryColor;
  final Color? tertiaryColor;
  final Color? backgroundColor;

  @override
  State<MeshGradientBackground> createState() => _MeshGradientBackgroundState();
}

class _MeshGradientBackgroundState extends State<MeshGradientBackground>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 15),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final bg = widget.backgroundColor ?? Colors.black;
    final primary = widget.primaryColor ?? c.primary.withValues(alpha: 0.6);
    final secondary =
        widget.secondaryColor ?? const Color(0xFFF4C84B).withValues(alpha: 0.4);
    final tertiary = widget.tertiaryColor ?? c.primary.withValues(alpha: 0.3);

    return Container(
      color: bg,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _AnimatedOrb(
            controller: _controller,
            color: primary,
            size: 300,
            offsetX: 0.3,
            offsetY: 0.2,
            speedX: 1.0,
            speedY: 1.5,
          ),
          _AnimatedOrb(
            controller: _controller,
            color: secondary,
            size: 400,
            offsetX: -0.4,
            offsetY: -0.3,
            speedX: -1.2,
            speedY: 0.8,
            initialPhase: pi / 2,
          ),
          _AnimatedOrb(
            controller: _controller,
            color: tertiary,
            size: 350,
            offsetX: 0.0,
            offsetY: 0.4,
            speedX: 0.7,
            speedY: -1.1,
            initialPhase: pi,
          ),
          // A huge blur filter over everything blends them into a mesh gradient
          BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 80, sigmaY: 80),
            child: const SizedBox.expand(),
          ),
        ],
      ),
    );
  }
}

class _AnimatedOrb extends StatelessWidget {
  const _AnimatedOrb({
    required this.controller,
    required this.color,
    required this.size,
    required this.offsetX,
    required this.offsetY,
    required this.speedX,
    required this.speedY,
    this.initialPhase = 0.0,
  });

  final AnimationController controller;
  final Color color;
  final double size;
  final double offsetX;
  final double offsetY;
  final double speedX;
  final double speedY;
  final double initialPhase;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        final t = controller.value * 2 * pi;
        final x = sin(t * speedX + initialPhase) *
            offsetX *
            MediaQuery.of(context).size.width;
        final y = cos(t * speedY + initialPhase) *
            offsetY *
            MediaQuery.of(context).size.height;

        return Align(
          alignment: Alignment.center,
          child: Transform.translate(
            offset: Offset(x, y),
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color,
              ),
            ),
          ),
        );
      },
    );
  }
}
