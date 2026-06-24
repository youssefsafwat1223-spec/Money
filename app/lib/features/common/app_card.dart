import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_gradients.dart';
import '../../core/theme/app_shadows.dart';
import '../../core/theme/app_spacing.dart';

enum AppCardVariant { base, elevated, gradient, danger }

/// بطاقة قياسية بتوكنات التصميم — سطح، زاوية، ظل، وحواف ناعمة.
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding,
    this.border,
    this.gradient,
    this.variant = AppCardVariant.base,
    this.margin,
    this.radius,
    this.semanticsLabel,
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry? padding;
  final Border? border;
  final Gradient? gradient;
  final AppCardVariant variant;
  final EdgeInsetsGeometry? margin;
  final double? radius;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final effectiveRadius = radius ?? AppRadius.card;
    final effectiveGradient = gradient ??
        switch (variant) {
          AppCardVariant.gradient => AppGradients.subtleSurface,
          AppCardVariant.danger => AppGradients.danger,
          _ => null,
        };
    final effectiveBorder = border ??
        Border.all(
          color: switch (variant) {
            AppCardVariant.danger => c.danger.withValues(alpha: 0.24),
            AppCardVariant.gradient => c.border.withValues(alpha: 0.8),
            _ => c.border,
          },
          width: 1.0,
        );
    final decoration = BoxDecoration(
      color: effectiveGradient == null ? c.surfaceCard : null,
      gradient: effectiveGradient,
      borderRadius: BorderRadius.circular(effectiveRadius),
      border: effectiveBorder,
      boxShadow: variant == AppCardVariant.elevated
          ? AppShadows.elevatedCard
          : AppShadows.card,
    );

    final content = Container(
      margin: margin,
      padding: padding ?? const EdgeInsets.all(AppSpacing.cardPadding),
      decoration: decoration,
      child: child,
    );

    if (onTap == null) return content;

    return Semantics(
      label: semanticsLabel,
      button: true,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(effectiveRadius),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(effectiveRadius),
          child: content,
        ),
      ),
    );
  }
}
