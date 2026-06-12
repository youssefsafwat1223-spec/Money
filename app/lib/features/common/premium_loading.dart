import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import 'motion.dart';

class PremiumSkeletonPage extends StatelessWidget {
  const PremiumSkeletonPage({
    super.key,
    this.withHero = true,
    this.cardCount = 4,
  });

  final bool withHero;
  final int cardCount;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        AppSpacing.s6,
        AppSpacing.gutter,
        120,
      ),
      children: [
        if (withHero) ...[
          _SkeletonBlock(
            height: 176,
            baseColor: c.surface,
            highlightColor: c.surface2,
            radius: AppRadius.cardLg,
          ),
          const SizedBox(height: AppSpacing.s5),
        ],
        for (var i = 0; i < cardCount; i++) ...[
          _SkeletonBlock(
            height: i == 0 ? 96 : 74,
            baseColor: c.surface,
            highlightColor: c.surface2,
            radius: AppRadius.card,
          ),
          const SizedBox(height: AppSpacing.s3),
        ],
      ],
    );
  }
}

class _SkeletonBlock extends StatefulWidget {
  const _SkeletonBlock({
    required this.height,
    required this.baseColor,
    required this.highlightColor,
    required this.radius,
  });

  final double height;
  final Color baseColor;
  final Color highlightColor;
  final double radius;

  @override
  State<_SkeletonBlock> createState() => _SkeletonBlockState();
}

class _SkeletonBlockState extends State<_SkeletonBlock>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (shouldReduceMotion(context)) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final sweep = shouldReduceMotion(context) ? 0.0 : _controller.value;
        return Container(
          height: widget.height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.radius),
            gradient: LinearGradient(
              begin: Alignment(-1.2 + sweep * 2.4, -0.8),
              end: Alignment(-0.2 + sweep * 2.4, 0.8),
              colors: [
                widget.baseColor,
                widget.highlightColor.withValues(alpha: 0.72),
                widget.baseColor,
              ],
            ),
          ),
        );
      },
    );
  }
}
