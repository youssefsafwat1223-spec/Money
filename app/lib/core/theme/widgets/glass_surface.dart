import 'dart:ui';

import 'package:flutter/material.dart';

import '../app_colors.dart';
import '../app_spacing.dart';

/// GlassSurface — frosted glass that mirrors the app's bottom navigation bar
/// **exactly**: the same fill (`c.surface` @ 66/72%), the same top→bottom
/// white→surface gradient, the same hairline, and the same blur. Used for the
/// account / date-range selectors and other frosted overlays on the canvas, so
/// every glass in the app reads as one material. (On iOS the nav itself is a
/// native `UIVisualEffectView`; this is the closest Flutter match, identical to
/// the nav's own Flutter fallback recipe.)
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.borderRadius,
    this.padding,
    this.blurSigma = 24,
  });

  final Widget child;
  final BorderRadius? borderRadius;
  final EdgeInsetsGeometry? padding;
  final double blurSigma;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final radius = borderRadius ?? BorderRadius.circular(AppRadius.pill);
    return ClipRRect(
      borderRadius: radius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: c.surface.withValues(alpha: isDark ? 0.66 : 0.72),
            borderRadius: radius,
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.white.withValues(alpha: isDark ? 0.08 : 0.52),
                c.surface.withValues(alpha: isDark ? 0.50 : 0.62),
              ],
            ),
            border: Border.all(
              color: Colors.white.withValues(alpha: isDark ? 0.14 : 0.66),
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}
