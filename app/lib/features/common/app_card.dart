import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_shadows.dart';
import '../../core/theme/app_spacing.dart';

/// بطاقة قياسية بتوكنات التصميم — سطح، زاوية، ظل، وحواف ناعمة.
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding,
    this.border,
    this.gradient,
    this.semanticsLabel,
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry? padding;
  final Border? border;
  final Gradient? gradient;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final decoration = BoxDecoration(
      color: gradient == null ? c.surface : null,
      gradient: gradient,
      borderRadius: BorderRadius.circular(AppRadius.card),
      border: border ?? Border.all(color: c.border, width: 1.0),
      boxShadow: AppShadows.card,
    );

    final content = Container(
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
        borderRadius: BorderRadius.circular(AppRadius.card),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.card),
          child: content,
        ),
      ),
    );
  }
}
