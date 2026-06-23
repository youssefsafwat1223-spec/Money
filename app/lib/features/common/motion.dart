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

class PremiumMotion extends StatelessWidget {
  const PremiumMotion({
    super.key,
    required this.child,
    this.delay = Duration.zero,
  });

  final Widget child;
  final Duration delay;

  @override
  Widget build(BuildContext context) {
    if (shouldReduceMotion(context)) {
      return child;
    }
    return child
        .animate(delay: delay)
        .fadeIn(duration: 180.ms, curve: AppMotion.standardCurve)
        .slideY(
            begin: 0.05, end: 0, duration: AppMotion.normal, curve: AppMotion.standardCurve);
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
    final duration = shouldReduceMotion(context)
        ? Duration.zero
        : AppMotion.numberCountUp;
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
