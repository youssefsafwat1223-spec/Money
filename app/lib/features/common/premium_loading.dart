import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import 'motion.dart';

/// First-load placeholder for a screen's initial provider load.
///
/// Startup already has a branded full-screen loader. A screen that still needs
/// its first provider result uses one quiet spinner instead of briefly exposing
/// an empty card skeleton that can be mistaken for the loaded UI.
class FirstLoadPlaceholder extends StatelessWidget {
  const FirstLoadPlaceholder({super.key, this.cardCount = 4});

  /// Kept for source compatibility with existing call sites.
  final int cardCount;

  @override
  Widget build(BuildContext context) {
    // iOS-native spinner (the one Apple/GitHub use), not the Material ring.
    return Center(
      child: CupertinoActivityIndicator(
        radius: 14,
        color: context.colors.textLight,
      ),
    );
  }
}

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
            baseColor: c.surfaceCard,
            highlightColor: c.surfaceMuted,
            radius: AppRadius.cardLg,
          ),
          const SizedBox(height: AppSpacing.s5),
        ],
        for (var i = 0; i < cardCount; i++) ...[
          _SkeletonBlock(
            height: i == 0 ? 96 : 74,
            baseColor: c.surfaceCard,
            highlightColor: c.surfaceMuted,
            radius: AppRadius.card,
          ),
          const SizedBox(height: AppSpacing.s3),
        ],
      ],
    );
  }
}

/// Row-shaped loading placeholder: a round 40px tile + two text bars + a
/// trailing amount bar — unmistakably "rows are coming", which sidesteps the
/// old concern that a generic block skeleton could be mistaken for the loaded
/// UI (the reason screens fell back to a bare spinner).
class SkeletonRow extends StatelessWidget {
  const SkeletonRow({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          SizedBox(
            width: AppSpacing.avatar,
            height: AppSpacing.avatar,
            child: _SkeletonBlock(
              height: AppSpacing.avatar,
              baseColor: c.surfaceMuted,
              highlightColor: c.surfaceElevated,
              radius: AppRadius.pill,
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FractionallySizedBox(
                  alignment: AlignmentDirectional.centerStart,
                  widthFactor: 0.55,
                  child: _SkeletonBlock(
                    height: 12,
                    baseColor: c.surfaceMuted,
                    highlightColor: c.surfaceElevated,
                    radius: 6,
                  ),
                ),
                const SizedBox(height: 7),
                FractionallySizedBox(
                  alignment: AlignmentDirectional.centerStart,
                  widthFactor: 0.32,
                  child: _SkeletonBlock(
                    height: 10,
                    baseColor: c.surfaceMuted,
                    highlightColor: c.surfaceElevated,
                    radius: 5,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 48,
            child: _SkeletonBlock(
              height: 12,
              baseColor: c.surfaceMuted,
              highlightColor: c.surfaceElevated,
              radius: 6,
            ),
          ),
        ],
      ),
    );
  }
}

/// First-load placeholder built from [SkeletonRow]s (optionally with a hero
/// block on top for screens whose first fold is a hero). Non-scrollable by
/// design — it stands in for content, it isn't content.
class SkeletonList extends StatelessWidget {
  const SkeletonList({super.key, this.rows = 6, this.withHero = false});

  final int rows;
  final bool withHero;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ListView(
      physics: const NeverScrollableScrollPhysics(),
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
            baseColor: c.surfaceCard,
            highlightColor: c.surfaceMuted,
            radius: AppRadius.cardLg,
          ),
          const SizedBox(height: AppSpacing.s5),
        ],
        for (var i = 0; i < rows; i++) const SkeletonRow(),
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
