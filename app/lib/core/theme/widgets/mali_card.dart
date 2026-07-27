import 'package:flutter/material.dart';

import '../app_shadows.dart';
import '../app_spacing.dart';
import '../mali_tokens.dart';

/// Depth variant for [MaliCard] — pick by importance, not decoration. See
/// docs/MALI_DESIGN_SYSTEM.md §1.1 surface hierarchy.
enum MaliSurfaceStyle {
  /// Quiet grouping (e.g. a list). No shadow — sits close to canvas.
  raised,

  /// The standard floating card. [AppShadows.floatSoft].
  floating,

  /// Frosted/glass fill + stroke, no shadow (pair with a real blur via
  /// [GlassSurface] when a backdrop blur is wanted).
  glass,

  /// Restrained accent gradient + glow — reserved for a small number of
  /// flagship moments (AI insight, selected state). Never the balance hero
  /// itself — see design doc §0.2.
  accent,
}

/// MaliCard — the single reusable card primitive for the flagship system.
/// Radius defaults to [AppRadius.xxl] (28, matching the HTML mockup card);
/// override for a smaller surface.
class MaliCard extends StatelessWidget {
  const MaliCard({
    super.key,
    required this.child,
    this.style = MaliSurfaceStyle.floating,
    this.padding = const EdgeInsets.all(AppSpacing.cardPadding),
    this.radius = AppRadius.xxl,
    this.onTap,
    this.onLongPress,
  });

  final Widget child;
  final MaliSurfaceStyle style;
  final EdgeInsetsGeometry padding;
  final double radius;

  /// When non-null the card becomes tappable. The press highlight/ripple is
  /// clipped to [radius] while the drop shadow stays unclipped.
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final t = MaliTokens.of(context);
    final borderRadius = BorderRadius.circular(radius);
    final decoration = switch (style) {
      MaliSurfaceStyle.raised => BoxDecoration(
          color: t.surfaceRaised,
          borderRadius: borderRadius,
        ),
      MaliSurfaceStyle.floating => BoxDecoration(
          color: t.surfaceFloating,
          borderRadius: borderRadius,
          border: Border.all(color: t.cardBorder),
          boxShadow: t.floatShadow,
        ),
      MaliSurfaceStyle.glass => BoxDecoration(
          color: t.surfaceGlassFill,
          borderRadius: borderRadius,
          border: Border.all(color: t.surfaceGlassStroke),
        ),
      MaliSurfaceStyle.accent => BoxDecoration(
          gradient: MaliTokens.accentGradient,
          borderRadius: borderRadius,
          boxShadow: AppShadows.heroGlow,
        ),
    };
    Widget inner = Padding(padding: padding, child: child);
    if (onTap != null || onLongPress != null) {
      // Clip only the ink layer (not the DecoratedBox) so the shadow survives.
      inner = ClipRRect(
        borderRadius: borderRadius,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            onLongPress: onLongPress,
            child: inner,
          ),
        ),
      );
    }
    return DecoratedBox(decoration: decoration, child: inner);
  }
}
