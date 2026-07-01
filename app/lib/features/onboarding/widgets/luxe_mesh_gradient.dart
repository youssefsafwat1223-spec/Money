import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';

class LuxeMeshGradient extends StatefulWidget {
  const LuxeMeshGradient({super.key});

  @override
  State<LuxeMeshGradient> createState() => _LuxeMeshGradientState();
}

class _LuxeMeshGradientState extends State<LuxeMeshGradient>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

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
    return Container(
      color: Colors.black, // Deep black background
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final time = _controller.value * 2 * pi;

          return Stack(
            children: [
              // Gold Orb
              Positioned(
                left: MediaQuery.of(context).size.width * 0.5 +
                    cos(time) * 100 -
                    150,
                top: MediaQuery.of(context).size.height * 0.2 +
                    sin(time) * 100 -
                    150,
                child: _buildOrb(const Color(0xFFDAA520), 300), // Luxe Gold
              ),
              // Earthy Brown Orb
              Positioned(
                right: MediaQuery.of(context).size.width * 0.2 +
                    cos(time + pi) * 120 -
                    150,
                bottom: MediaQuery.of(context).size.height * 0.3 +
                    sin(time + pi) * 120 -
                    150,
                child: _buildOrb(const Color(0xFF8B4513), 300), // Earthy Brown
              ),
              // Subtle Silver Orb
              Positioned(
                left: MediaQuery.of(context).size.width * 0.2 +
                    cos(time + pi / 2) * 80 -
                    100,
                bottom: MediaQuery.of(context).size.height * 0.1 +
                    sin(time + pi / 2) * 80 -
                    100,
                child: _buildOrb(const Color(0xFFC0C0C0).withValues(alpha: 0.15), 200), // Silver accent
              ),
              // Heavy glass blur over the orbs to create the mesh effect
              Positioned.fill(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 100, sigmaY: 100),
                  child: Container(color: Colors.transparent),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildOrb(Color color, double size) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: 0.6),
      ),
    );
  }
}
