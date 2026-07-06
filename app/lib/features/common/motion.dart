import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../core/theme/app_typography.dart';
import '../../core/theme/app_motion.dart';
import '../../core/utils/formatters.dart';

bool shouldReduceMotion(BuildContext context) {
  final media = MediaQuery.maybeOf(context);
  return media?.disableAnimations ?? false;
}

class PremiumMotion extends StatefulWidget {
  const PremiumMotion({
    super.key,
    required this.child,
    this.delay = Duration.zero,
  });

  final Widget child;
  final Duration delay;

  @override
  State<PremiumMotion> createState() => _PremiumMotionState();
}

class _PremiumMotionState extends State<PremiumMotion> {
  // Entrance animation plays once per mount. After it completes we render the
  // plain child, so provider-driven rebuilds (a toggle, a data refresh) never
  // replay the fade/slide — that replay is the "page disappears and reappears"
  // flicker.
  bool _played = false;

  @override
  Widget build(BuildContext context) {
    if (_played || shouldReduceMotion(context)) {
      return widget.child;
    }
    return widget.child
        .animate(
          delay: widget.delay,
          onComplete: (_) {
            if (mounted) setState(() => _played = true);
          },
        )
        .fadeIn(duration: 180.ms, curve: AppMotion.standardCurve)
        .slideY(
            begin: 0.05,
            end: 0,
            duration: AppMotion.normal,
            curve: AppMotion.standardCurve);
  }
}

class AnimatedAmountText extends StatelessWidget {
  const AnimatedAmountText({
    super.key,
    required this.amount,
    required this.color,
    this.suffix = '',
    this.textAlign = TextAlign.center,
    this.style,
  });

  final double amount;
  final Color color;
  final String suffix;
  final TextAlign textAlign;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final duration =
        shouldReduceMotion(context) ? Duration.zero : AppMotion.numberCountUp;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: amount),
      duration: duration,
      curve: AppMotion.standardCurve,
      builder: (context, value, _) {
        final baseStyle = style ?? AppTypography.title2(color);
        return Text(
          '${Formatters.amount(value)}$suffix',
          textAlign: textAlign,
          style: baseStyle.copyWith(
            color: color,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        );
      },
    );
  }
}
